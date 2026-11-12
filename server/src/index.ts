// Tape share server.
//
// Public, unlisted pages:  GET /recordings/:id  (anyone with the link can watch)
// Owner-only API:           /api/*             (Authorization: Bearer UPLOAD_TOKEN)
//
// Set BASE_PATH (e.g. "/tape") to serve everything under a path on a shared
// domain: https://example.com/tape/recordings/:id. Old /v/:id links still work.
//
// Videos and captions live in a private R2 bucket and are only ever read
// through this Worker. Share metadata and view counts live in D1.

interface Env {
  BUCKET: R2Bucket;
  DB: D1Database;
  UPLOAD_TOKEN: string;
  BASE_PATH?: string;
}

/** BASE_PATH without a trailing slash: "" or "/tape". */
function basePath(env: Env): string {
  const b = (env.BASE_PATH ?? "").replace(/\/+$/, "");
  return b && !b.startsWith("/") ? "/" + b : b;
}

function shareURL(url: URL, env: Env, id: string): string {
  return `${url.origin}${basePath(env)}/recordings/${id}`;
}

interface Share {
  id: string;
  title: string;
  duration: number;
  created_at: number;
  version: number;
  views: number;
}

// Tape's icon (red rounded square, white dot), inline so the tab shows it.
const FAVICON = "data:image/svg+xml," + encodeURIComponent(
  "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'><rect width='100' height='100' rx='24' fill='#d0402b'/>" +
  "<circle cx='50' cy='50' r='20' fill='#fff'/></svg>");

import CARD from "./card.png";

const ID = /^[0-9A-Za-z]{12}$/;
const MAX_CAPTIONS_BYTES = 2 * 1024 * 1024;
const MAX_POSTER_BYTES = 2 * 1024 * 1024;

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    try {
      return await route(request, env);
    } catch (error) {
      console.error(error);
      return text("Something went wrong.", 500);
    }
  },
} satisfies ExportedHandler<Env>;

async function route(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  const base = basePath(env);
  let path = url.pathname;
  if (base) {
    if (path !== base && !path.startsWith(base + "/")) return notFound();
    path = path.slice(base.length) || "/";
  }
  const parts = path.split("/").filter(Boolean);
  const method = request.method;

  if (parts[0] === "api") {
    if (!(await authorized(request, env))) return json({ error: "unauthorized" }, 401);
    return api(request, env, url, parts.slice(1), method);
  }

  if ((parts[0] === "recordings" || parts[0] === "v") && parts[1] && ID.test(parts[1])) {
    const share = await getShare(env, parts[1]);
    if (!share || share.version === 0) return notFound();
    const rest = parts.slice(2).join("/");
    if (rest === "" && method === "GET") return page(share, url, `${base}/${parts[0]}/${share.id}`);
    if (rest === "video.mp4" && (method === "GET" || method === "HEAD")) return video(request, env, share);
    if (rest === "captions.vtt" && method === "GET") return captionsFile(env, share, "vtt", false);
    if (rest === "poster.jpg" && (method === "GET" || method === "HEAD")) return poster(env, share);
    const download = rest.match(/^transcript\.(txt|srt|vtt|md)$/);
    if (download && method === "GET") return captionsFile(env, share, download[1] as Format, true);
    if (rest === "view" && method === "POST") {
      await env.DB.prepare("UPDATE shares SET views = views + 1 WHERE id = ? AND version > 0").bind(share.id).run();
      return new Response(null, { status: 204 });
    }
    return notFound();
  }

  if (path === "/robots.txt") return text("User-agent: *\nDisallow: /\n");
  return notFound();
}

// MARK: Owner API

async function api(request: Request, env: Env, url: URL, parts: string[], method: string): Promise<Response> {
  // POST /api/shares  { title, duration }  → { id, url }
  if (parts.length === 1 && parts[0] === "shares" && method === "POST") {
    const body = await request.json<{ title?: string; duration?: number }>().catch(() => ({}) as never);
    const id = randomID();
    await env.DB.prepare("INSERT INTO shares (id, title, duration, created_at) VALUES (?, ?, ?, ?)")
      .bind(id, cleanTitle(body?.title), Number(body?.duration) || 0, Date.now())
      .run();
    return json({ id, url: shareURL(url, env, id) }, 201);
  }

  if (parts[0] !== "shares" || !parts[1] || !ID.test(parts[1])) return json({ error: "not found" }, 404);
  const id = parts[1];
  const share = await getShare(env, id);
  if (!share) return json({ error: "not found" }, 404);
  const rest = parts.slice(2);
  const videoKey = `shares/${id}/video.mp4`;

  // GET /api/shares/:id  → details and view count
  if (rest.length === 0 && method === "GET") {
    return json({ id, url: shareURL(url, env, id), title: share.title, views: share.views,
                  ready: share.version > 0, updatedAt: share.version || null });
  }

  // DELETE /api/shares/:id  → removes the files and the row; the link 404s
  if (rest.length === 0 && method === "DELETE") {
    const listed = await env.BUCKET.list({ prefix: `shares/${id}/` });
    if (listed.objects.length) await env.BUCKET.delete(listed.objects.map((o) => o.key));
    await env.DB.prepare("DELETE FROM shares WHERE id = ?").bind(id).run();
    return new Response(null, { status: 204 });
  }

  // PUT /api/shares/:id/captions  (WebVTT body)
  if (rest.length === 1 && rest[0] === "captions" && method === "PUT") {
    const body = await request.text();
    if (body.length > MAX_CAPTIONS_BYTES || !body.startsWith("WEBVTT")) return json({ error: "bad captions" }, 400);
    await env.BUCKET.put(`shares/${id}/captions.vtt`, body, { httpMetadata: { contentType: "text/vtt; charset=utf-8" } });
    return new Response(null, { status: 204 });
  }

  // PUT /api/shares/:id/poster  (JPEG body): the link-preview image
  if (rest.length === 1 && rest[0] === "poster" && method === "PUT") {
    const body = await request.arrayBuffer();
    const bytes = new Uint8Array(body);
    if (body.byteLength > MAX_POSTER_BYTES || bytes[0] !== 0xff || bytes[1] !== 0xd8) return json({ error: "bad poster" }, 400);
    await env.BUCKET.put(`shares/${id}/poster.jpg`, body, { httpMetadata: { contentType: "image/jpeg" } });
    return new Response(null, { status: 204 });
  }

  // Video upload in parts, through the Worker (no R2 keys leave Cloudflare).
  // Every part but the last must be the same size, at least 5 MiB.
  // POST /api/shares/:id/video  → { uploadId }
  if (rest.length === 1 && rest[0] === "video" && method === "POST") {
    const upload = await env.BUCKET.createMultipartUpload(videoKey, { httpMetadata: { contentType: "video/mp4" } });
    return json({ uploadId: upload.uploadId });
  }
  // The upload id goes in the query (?upload=…): R2 ids can contain "/".
  const uploadId = url.searchParams.get("upload");
  if (rest[0] === "video" && uploadId) {
    const upload = env.BUCKET.resumeMultipartUpload(videoKey, uploadId);
    // PUT /api/shares/:id/video/:partNumber?upload=…  → { partNumber, etag }
    if (rest.length === 2 && /^\d+$/.test(rest[1]) && method === "PUT") {
      const partNumber = Number(rest[1]);
      if (!Number.isInteger(partNumber) || partNumber < 1 || partNumber > 10000 || !request.body) {
        return json({ error: "bad part" }, 400);
      }
      const part = await upload.uploadPart(partNumber, request.body);
      return json({ partNumber: part.partNumber, etag: part.etag });
    }
    // POST /api/shares/:id/video/complete?upload=…  { parts, title?, duration? }
    if (rest.length === 2 && rest[1] === "complete" && method === "POST") {
      const body = await request.json<{ parts: R2UploadedPart[]; title?: string; duration?: number }>();
      await upload.complete(body.parts);
      await env.DB.prepare("UPDATE shares SET version = ?, title = ?, duration = ? WHERE id = ?")
        .bind(Date.now(), body.title ? cleanTitle(body.title) : share.title, Number(body.duration) || share.duration, id)
        .run();
      return json({ id, url: shareURL(url, env, id) });
    }
    // DELETE /api/shares/:id/video?upload=…  → abandon a failed upload
    if (rest.length === 1 && method === "DELETE") {
      await upload.abort();
      return new Response(null, { status: 204 });
    }
  }
  return json({ error: "not found" }, 404);
}

async function authorized(request: Request, env: Env): Promise<boolean> {
  const header = request.headers.get("Authorization") ?? "";
  if (!env.UPLOAD_TOKEN || env.UPLOAD_TOKEN.length < 16 || !header.startsWith("Bearer ")) return false;
  // Compare digests so the comparison takes the same time whatever the input.
  const enc = new TextEncoder();
  const [a, b] = await Promise.all([
    crypto.subtle.digest("SHA-256", enc.encode(header.slice(7))),
    crypto.subtle.digest("SHA-256", enc.encode(env.UPLOAD_TOKEN)),
  ]);
  return crypto.subtle.timingSafeEqual(a, b);
}

function randomID(): string {
  const alphabet = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
  const out: string[] = [];
  // Rejection sampling: 62 doesn't divide 256, so drop bytes ≥ 248.
  while (out.length < 12) {
    for (const byte of crypto.getRandomValues(new Uint8Array(16))) {
      if (byte < 248 && out.length < 12) out.push(alphabet[byte % 62]);
    }
  }
  return out.join("");
}

function cleanTitle(title: unknown): string {
  const s = typeof title === "string" ? title.replace(/[\u0000-\u001f]/g, "").trim() : "";
  return s.slice(0, 200) || "Untitled recording";
}

async function getShare(env: Env, id: string): Promise<Share | null> {
  return env.DB.prepare("SELECT * FROM shares WHERE id = ?").bind(id).first<Share>();
}

// MARK: Public files

async function video(request: Request, env: Env, share: Share): Promise<Response> {
  const key = `shares/${share.id}/video.mp4`;
  const object = await env.BUCKET.get(key, { range: request.headers, onlyIf: request.headers });
  if (!object) return notFound();
  const headers = new Headers({
    "Content-Type": "video/mp4",
    "Accept-Ranges": "bytes",
    "ETag": object.httpEtag,
    "Cache-Control": "private, max-age=3600",
    ...securityHeaders(),
  });
  if (!("body" in object)) return new Response(null, { status: 304, headers }); // precondition matched

  const size = object.size;
  const range = object.range as { offset?: number; length?: number; suffix?: number } | undefined;
  let status = 200;
  let length = size;
  if (range && request.headers.has("Range")) {
    let start: number, end: number;
    if (range.suffix !== undefined) {
      start = Math.max(size - range.suffix, 0);
      end = size - 1;
    } else {
      start = range.offset ?? 0;
      end = range.length !== undefined ? start + range.length - 1 : size - 1;
    }
    end = Math.min(end, size - 1);
    length = end - start + 1;
    status = 206;
    headers.set("Content-Range", `bytes ${start}-${end}/${size}`);
  }
  headers.set("Content-Length", String(length));
  return new Response(request.method === "HEAD" ? null : object.body, { status, headers });
}

type Format = "vtt" | "srt" | "txt" | "md";

async function captionsFile(env: Env, share: Share, format: Format, attachment: boolean): Promise<Response> {
  const object = await env.BUCKET.get(`shares/${share.id}/captions.vtt`);
  const vtt = object ? await object.text() : "WEBVTT\n";
  const cues = parseVTT(vtt);
  const body = format === "vtt" ? vtt : format === "srt" ? toSRT(cues) : format === "md" ? toMarkdown(share, cues)
    : cues.map((c) => c.text).join("\n") + "\n";
  const types = { vtt: "text/vtt", srt: "application/x-subrip", txt: "text/plain", md: "text/markdown" };
  const headers: Record<string, string> = {
    "Content-Type": `${types[format]}; charset=utf-8`,
    "Cache-Control": "private, max-age=60",
    ...securityHeaders(),
  };
  if (attachment) {
    const name = share.title.replace(/[^\p{L}\p{N} ._-]+/gu, "").trim() || "transcript";
    headers["Content-Disposition"] = `attachment; filename="transcript.${format}"; filename*=UTF-8''${encodeURIComponent(name)}.${format}`;
  }
  return new Response(body, { headers });
}

interface Cue { start: number; end: number; text: string }

function parseVTT(vtt: string): Cue[] {
  const cues: Cue[] = [];
  for (const block of vtt.replace(/\r/g, "").split(/\n\n+/)) {
    const lines = block.split("\n");
    const at = lines.findIndex((l) => l.includes("-->"));
    if (at < 0) continue;
    const [a, b] = lines[at].split("-->").map((s) => s.trim().split(/\s+/)[0]);
    const text = lines.slice(at + 1).join("\n").trim();
    if (text) cues.push({ start: seconds(a), end: seconds(b), text });
  }
  return cues;
}

function seconds(stamp: string): number {
  const p = stamp.split(":").map(Number);
  return p.length === 3 ? p[0] * 3600 + p[1] * 60 + p[2] : p[0] * 60 + p[1];
}

/// A heading, then one timestamped line per caption.
function toMarkdown(share: Share, cues: Cue[]): string {
  const stamp = (t: number) => formatDuration(Math.floor(t));
  // Escape characters that would turn transcript text into Markdown syntax.
  const md = (s: string) => s.replace(/[\\`*_{}\[\]<>#|~]/g, "\\$&").replace(/\n/g, " ");
  return `# ${md(share.title)}\n\n` + cues.map((c) => `**${stamp(c.start)}** ${md(c.text)}  `).join("\n") + "\n";
}

function toSRT(cues: Cue[]): string {
  const stamp = (t: number) => {
    const ms = Math.round(t * 1000);
    const pad = (n: number, w = 2) => String(n).padStart(w, "0");
    return `${pad(Math.floor(ms / 3600000))}:${pad(Math.floor(ms / 60000) % 60)}:${pad(Math.floor(ms / 1000) % 60)},${pad(ms % 1000, 3)}`;
  };
  return cues.map((c, i) => `${i + 1}\n${stamp(c.start)} --> ${stamp(c.end)}\n${c.text}\n`).join("\n");
}

// MARK: The page

async function page(share: Share, url: URL, base: string): Promise<Response> {
  const nonce = btoa(String.fromCharCode(...crypto.getRandomValues(new Uint8Array(16))));
  const v = share.version;
  const title = escapeHTML(share.title);
  const absolute = url.origin + base;
  const image = `${absolute}/poster.jpg?v=${v}`;
  const videoURL = `${absolute}/video.mp4?v=${v}`;
  const description = share.duration > 0
    ? `${formatDuration(share.duration)} video with a transcript, recorded with Tape.`
    : "A video with a transcript, recorded with Tape.";
  const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<meta name="referrer" content="no-referrer">
<meta property="og:site_name" content="Tape">
<meta property="og:title" content="${title}">
<meta property="og:description" content="${escapeHTML(description)}">
<meta property="og:type" content="video.other">
<meta property="og:url" content="${escapeHTML(url.origin + base)}">
<meta property="og:image" content="${escapeHTML(image)}">
<meta property="og:image:alt" content="${title}">
<meta property="og:video" content="${escapeHTML(videoURL)}">
<meta property="og:video:secure_url" content="${escapeHTML(videoURL)}">
<meta property="og:video:type" content="video/mp4">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="${title}">
<meta name="twitter:description" content="${escapeHTML(description)}">
<meta name="twitter:image" content="${escapeHTML(image)}">
<meta name="description" content="${escapeHTML(description)}">
<title>${title}</title>
<link rel="icon" type="image/svg+xml" href="${FAVICON}">
<style nonce="${nonce}">
:root { --bg:#fff; --fg:#1d1d1f; --muted:#6e6e73; --line:#e5e5ea; --panel:#f5f5f7; --accent:#0a84ff; --hl:rgba(10,132,255,.14); }
@media (prefers-color-scheme: dark) { :root { --bg:#111113; --fg:#f5f5f7; --muted:#98989d; --line:#2c2c2e; --panel:#1c1c1e; --hl:rgba(10,132,255,.28); } }
* { box-sizing: border-box; }
html, body { margin:0; background:var(--bg); color:var(--fg); font:15px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif; }
main { max-width:1280px; margin:0 auto; padding:24px; display:grid; grid-template-columns:minmax(0,1fr) 360px; gap:24px; }
h1 { font-size:20px; margin:0 0 4px; font-weight:650; overflow-wrap:anywhere; }
.meta { color:var(--muted); font-size:13px; margin:0 0 16px; }
video { width:100%; max-height:75vh; background:#000; border-radius:12px; display:block; }
aside { background:var(--panel); border-radius:12px; display:flex; flex-direction:column; max-height:calc(75vh + 60px); min-height:0; }
.bar { display:flex; align-items:center; gap:6px; padding:12px 14px; border-bottom:1px solid var(--line); flex-wrap:wrap; }
.bar strong { margin-right:auto; font-size:14px; }
.bar a, .bar button { font:inherit; font-size:12px; color:var(--fg); background:var(--bg); border:1px solid var(--line); border-radius:6px; padding:3px 8px; text-decoration:none; cursor:pointer; }
.bar a:hover, .bar button:hover { border-color:var(--accent); }
ol { list-style:none; margin:0; padding:8px; overflow-y:auto; flex:1; }
li { display:flex; gap:10px; padding:6px 8px; border-radius:6px; cursor:pointer; }
li:hover { background:var(--line); }
li.now { background:var(--hl); }
li time { color:var(--muted); font-size:12px; font-variant-numeric:tabular-nums; padding-top:2px; min-width:36px; }
.empty { color:var(--muted); padding:16px; }
footer { grid-column:1/-1; color:var(--muted); font-size:12px; }
.controls { display:flex; align-items:center; gap:6px; margin-top:10px; flex-wrap:wrap; }
.controls .label { color:var(--muted); font-size:12px; margin-right:2px; }
.controls button { font:inherit; font-size:12px; color:var(--fg); background:var(--panel); border:1px solid var(--line); border-radius:6px; padding:3px 9px; cursor:pointer; font-variant-numeric:tabular-nums; }
.controls button:hover { border-color:var(--accent); }
#speeds button[aria-pressed="true"] { background:var(--accent); border-color:var(--accent); color:#fff; }
.controls .spacer { flex:1; }
main.no-transcript { grid-template-columns:minmax(0,1fr); max-width:1100px; }
main.no-transcript aside { display:none; }
@media (max-width: 860px) {
  main { grid-template-columns:1fr; padding:16px; gap:16px; }
  aside { max-height:60vh; }
}
</style>
</head>
<body>
<main id="main">
  <section>
    <h1>${title}</h1>
    <p class="meta">${formatDuration(share.duration)} · ${new Date(share.version).toLocaleDateString("en-US", { year: "numeric", month: "long", day: "numeric" })}</p>
    <video id="video" controls playsinline preload="metadata" crossorigin="anonymous" poster="${base}/poster.jpg?v=${v}" src="${base}/video.mp4?v=${v}">
      <track kind="captions" src="${base}/captions.vtt?v=${v}" srclang="en" label="Captions" default>
    </video>
    <div class="controls">
      <span class="label">Speed</span>
      <span id="speeds"></span>
      <span class="spacer"></span>
      <button id="toggle" type="button" aria-pressed="true">Transcript</button>
    </div>
  </section>
  <aside>
    <div class="bar">
      <strong>Transcript</strong>
      <button id="copy" type="button">Copy</button>
      <a href="${base}/transcript.md?v=${v}" download>.md</a>
      <a href="${base}/transcript.txt?v=${v}" download>.txt</a>
      <a href="${base}/transcript.srt?v=${v}" download>.srt</a>
      <a href="${base}/transcript.vtt?v=${v}" download>.vtt</a>
    </div>
    <ol id="lines"><li class="empty">Loading…</li></ol>
  </aside>
  <footer>Recorded with Tape</footer>
</main>
<script nonce="${nonce}">
(() => {
  const video = document.getElementById("video");
  const list = document.getElementById("lines");
  let cues = [], items = [], current = -1, lastUserScroll = 0, counted = false;

  const stamp = (t) => { t = Math.floor(t); return Math.floor(t / 60) + ":" + String(t % 60).padStart(2, "0"); };

  // Built with textContent only: transcript text is never parsed as HTML.
  fetch("${base}/captions.vtt?v=${v}").then((r) => r.text()).then((vtt) => {
    cues = vtt.replace(/\\r/g, "").split(/\\n\\n+/).map((block) => {
      const lines = block.split("\\n"), at = lines.findIndex((l) => l.includes("-->"));
      if (at < 0) return null;
      const [a, b] = lines[at].split("-->").map((s) => s.trim().split(/\\s+/)[0].split(":").map(Number));
      const sec = (p) => p.length === 3 ? p[0] * 3600 + p[1] * 60 + p[2] : p[0] * 60 + p[1];
      const text = lines.slice(at + 1).join(" ").trim();
      return text ? { start: sec(a), end: sec(b), text } : null;
    }).filter(Boolean);
    list.replaceChildren();
    if (!cues.length) { const li = document.createElement("li"); li.className = "empty"; li.textContent = "No transcript."; list.append(li); }
    items = cues.map((cue) => {
      const li = document.createElement("li"), time = document.createElement("time"), span = document.createElement("span");
      time.textContent = stamp(cue.start);
      span.textContent = cue.text;
      li.append(time, span);
      li.addEventListener("click", () => { video.currentTime = cue.start + 0.01; video.play(); });
      list.append(li);
      return li;
    });
  });

  list.addEventListener("wheel", () => { lastUserScroll = Date.now(); }, { passive: true });
  list.addEventListener("touchmove", () => { lastUserScroll = Date.now(); }, { passive: true });

  video.addEventListener("timeupdate", () => {
    const t = video.currentTime;
    const i = cues.findIndex((c) => t >= c.start && t < c.end);
    if (i === current) return;
    if (items[current]) items[current].classList.remove("now");
    current = i;
    const li = items[i];
    if (!li) return;
    li.classList.add("now");
    if (Date.now() - lastUserScroll > 4000) {
      list.scrollTo({ top: li.offsetTop - list.clientHeight / 3, behavior: "smooth" });
    }
  });

  // One view per page load, counted when playback starts (link previews
  // and bots that only fetch the page don't count).
  video.addEventListener("play", () => {
    if (counted) return;
    counted = true;
    fetch("${base}/view", { method: "POST", keepalive: true }).catch(() => {});
  });

  // Playback speed, remembered per browser. Pitch stays natural.
  const speedBox = document.getElementById("speeds");
  const store = { get(k) { try { return localStorage.getItem(k); } catch { return null; } },
                  set(k, v) { try { localStorage.setItem(k, v); } catch {} } };
  const setSpeed = (rate) => {
    video.playbackRate = rate;
    video.preservesPitch = true;
    for (const b of speedBox.children) b.setAttribute("aria-pressed", String(Number(b.dataset.rate) === rate));
    store.set("tape-speed", String(rate));
  };
  for (const rate of [1, 1.25, 1.5, 1.75, 2]) {
    const b = document.createElement("button");
    b.type = "button";
    b.dataset.rate = String(rate);
    b.textContent = rate + "×";
    b.addEventListener("click", () => setSpeed(rate));
    speedBox.append(b, " ");
  }
  const savedRate = Number(store.get("tape-speed"));
  setSpeed([1, 1.25, 1.5, 1.75, 2].includes(savedRate) ? savedRate : 1);
  // The browser's own speed menu changes it too; keep the buttons in step.
  video.addEventListener("ratechange", () => {
    for (const b of speedBox.children) b.setAttribute("aria-pressed", String(Number(b.dataset.rate) === video.playbackRate));
  });

  // Show or hide the transcript, remembered per browser.
  const main = document.getElementById("main"), toggle = document.getElementById("toggle");
  const showTranscript = (show) => {
    main.classList.toggle("no-transcript", !show);
    toggle.setAttribute("aria-pressed", String(show));
    toggle.textContent = show ? "Hide Transcript" : "Show Transcript";
    store.set("tape-transcript", show ? "1" : "0");
  };
  showTranscript(store.get("tape-transcript") !== "0");
  toggle.addEventListener("click", () => showTranscript(main.classList.contains("no-transcript")));

  document.getElementById("copy").addEventListener("click", async (e) => {
    try {
      await navigator.clipboard.writeText(cues.map((c) => c.text).join("\\n"));
      e.target.textContent = "Copied";
      setTimeout(() => { e.target.textContent = "Copy"; }, 1500);
    } catch {}
  });
})();
</script>
</body>
</html>`;
  return new Response(html, {
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": "no-store",
      "Content-Security-Policy": [
        "default-src 'none'",
        `script-src 'nonce-${nonce}'`,
        `style-src 'nonce-${nonce}'`,
        "media-src 'self'",
        "connect-src 'self'",
        "img-src 'self' data:",
        "base-uri 'none'",
        "form-action 'none'",
        "frame-ancestors 'none'",
      ].join("; "),
      ...securityHeaders(),
    },
  });
}

function formatDuration(seconds: number): string {
  const s = Math.round(seconds);
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
}

function escapeHTML(s: string): string {
  return s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);
}

function securityHeaders(): Record<string, string> {
  return {
    "X-Content-Type-Options": "nosniff",
    "X-Robots-Tag": "noindex, nofollow",
    "Referrer-Policy": "no-referrer",
  };
}

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store", ...securityHeaders() },
  });
}

function text(body: string, status = 200): Response {
  return new Response(body, { status, headers: { "Content-Type": "text/plain; charset=utf-8", ...securityHeaders() } });
}

/** The share's preview image, or the generic Tape card if it has none. */
async function poster(env: Env, share: Share): Promise<Response> {
  const object = await env.BUCKET.get(`shares/${share.id}/poster.jpg`);
  const headers = new Headers({ "Cache-Control": "public, max-age=86400", ...securityHeaders() });
  if (object) {
    headers.set("Content-Type", "image/jpeg");
    return new Response(object.body, { headers });
  }
  headers.set("Content-Type", "image/png");
  return new Response(CARD, { headers });
}

function notFound(): Response {
  return text("This link doesn't exist or was removed.", 404);
}
