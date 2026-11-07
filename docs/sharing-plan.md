# Sharing plan: hosted links with a transcript

Status: **v1 built and tested locally (2026-11-07); not deployed yet.** See
"What was built" at the end. Deploy steps are in `server/README.md`. The design
below is the original plan; where v1 differs, "What was built" wins.

## Goal
A **Share** button in the editor window uploads the edited recording and its
transcript, then copies a link like `https://tape.<domain>/v/k3x9q2mT7pQa` to the
clipboard. Anyone with the link sees a web page with:
- the video player
- the transcript beside it: click a line to jump there, and the current line is highlighted
- captions on the video (a WebVTT track)
- download links for the transcript (`.txt`, `.srt`, `.vtt`)

## Why Cloudflare
- **R2** (object storage) has **no egress fees**. Video is heavy, so on S3 or
  Vercel you would pay for every view. R2 is about $0.015/GB/month, and the
  first 10 GB is free. That's roughly 200 recordings for $0.
- **Workers** host the viewer page and a small API. The free tier is plenty.
- **Cloudflare Stream** (adaptive HLS) is **not needed**. A plain H.264 MP4 from
  R2 plays fine, and seeking works because R2 supports HTTP range requests. If
  viewers on slow connections become a problem, revisit Stream or Bunny.net.
- These prices are from memory, so check them on Cloudflare's pricing pages.

## Architecture
```
Tape (Mac)                         Cloudflare
──────────                         ──────────
Share clicked
  1. Export MP4 to a temp folder   (reuse Exporter.export, burnCaptions: false)
  2. POST /api/shares  ─────────▶  Worker: auth check, make the random id,
     (Bearer token)                 return presigned R2 PUT URLs
  3. PUT video.mp4 ────────────▶  R2  shares/<id>/video.mp4
     PUT captions.vtt ─────────▶  R2  shares/<id>/captions.vtt
     PUT meta.json ────────────▶  R2  shares/<id>/meta.json  (title, duration, createdAt)
  4. POST /api/shares/<id>/done ▶  Worker marks the share live
  5. Copy the link to the clipboard

Viewer browser
  GET /v/<id>          ─────────▶  Worker renders the HTML page (player + transcript)
  GET /v/<id>/video.mp4 ───────▶  Worker streams from R2 and passes Range through
  GET /v/<id>/transcript.{txt,srt,vtt} ▶ Worker reads captions.vtt and converts it
```

**Why presigned uploads instead of uploading through the Worker:** a Worker
request body is limited to about 100 MB, and recordings can be bigger. With
presigned URLs the app uploads straight to R2. Generate them in the Worker with
`aws4fetch` and R2's S3-compatible API keys, stored as Worker secrets.

## Security
1. **Only the owner can upload.** `/api/*` needs `Authorization: Bearer <TAPE_UPLOAD_TOKEN>`.
   The token is a Worker secret on the server side and is stored in the **macOS Keychain** in
   the app, never in UserDefaults or the source. Settings gets a "Sharing" section
   with the server URL and token fields.
2. **The bucket is private.** It has no public `r2.dev` access and no public listing.
   Everything is read through the Worker.
3. **Share ids can't be guessed.** Use at least 12 random base62 characters (`crypto.getRandomValues`).
   Never use file names or numbers in order.
4. **Presigned PUT URLs expire after 15 minutes** and only work for the keys under `shares/<id>/`.
5. **Revoking a share:** `DELETE /api/shares/<id>` deletes the objects. Optional later
   additions: an expiry date stored in `meta.json`, or Cloudflare Access in front of
   `/v/*` for private shares.
6. The viewer page escapes all transcript text (no `innerHTML` with transcript content)
   and sets a strict CSP header.
7. **Privacy promise:** the README currently says "Tape's own code never touches the
   network." Sharing must be **opt-in and off until it's configured**: nothing
   uploads until the user enters a server and token and clicks Share. Update the
   README's privacy section when this ships.

## Work in the Mac app (Swift)
Relevant code:
- `Sources/Tape/EditorWindow.swift`: `exportClicked()` / `export(timeline:to:burnCaptions:saveTranscript:)`
  (around line 722). Add a **Share** button and a `shareClicked()` next to Export, and
  reuse the same `Exporter.export(...)` call with `self.captions`,
  and `burnCaptions: false` (the web page shows captions as a track).
- `Sources/Tape/Edits.swift`: `struct Caption` already has `srt(_:)` and `plainText(_:)`.
  **Add `static func vtt(_ captions: [Caption]) -> String`**. It's the same as srt, but with a
  `WEBVTT\n\n` header, `.` instead of `,` in the timestamps, and no cue numbers needed.
- `Sources/Tape/Settings.swift`: add the server URL and a Keychain-backed token.
- New `Sources/Tape/Uploader.swift`: `URLSession` upload tasks for progress, which the status
  bar shows with the existing `setStatus("Uploading 42%…", busy: true)` pattern.
  When it finishes: `setStatus("Link copied", action: ("Open", { open URL }))`.
- Remember shares per recording in `<name>.share.json` (id, url, uploadedAt), so
  clicking Share again offers "Copy Link / Update / Delete Share" instead of uploading a new copy.
- Entitlements: add `com.apple.security.network.client` only if the app is sandboxed.
  It's currently hardened runtime without a sandbox, so check `Tape.entitlements`.

## Work on the server (new folder, e.g. `server/` in this repo)
- `wrangler.toml`: R2 binding `BUCKET` → bucket `tape-shares`; secrets
  `TAPE_UPLOAD_TOKEN`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_ACCOUNT_ID`.
- One TypeScript Worker with these routes:
  - `POST /api/shares` → `{ id, url, uploads: { video, captions, meta } }` (the presigned PUT URLs)
  - `POST /api/shares/:id/done`, `DELETE /api/shares/:id`
  - `GET /v/:id` → the HTML page (inline CSS/JS, no framework, works in light and dark mode, works on a phone)
  - `GET /v/:id/video.mp4` → `BUCKET.get(key, { range })`, which returns 206 with `Content-Range` and `Accept-Ranges: bytes`
  - `GET /v/:id/transcript.(vtt|srt|txt)` → converted from captions.vtt, with `Content-Disposition: attachment`
- Deploy with `npx wrangler deploy` and use a custom domain (e.g. `tape.<domain>`).

## Done when
- [ ] Click Share on a recording → a link is on the clipboard within the upload time
- [ ] The link plays in Safari and Chrome (and on a phone), seeking works, and captions show
- [ ] Clicking a transcript line seeks there; the line playing now is highlighted
- [ ] All three transcript downloads work
- [ ] A request to `/api/*` without the token gets a 401; the bucket isn't reachable directly
- [ ] Delete Share → the link returns 404
- [ ] With Sharing not configured, Tape makes no network requests

## What was built (v1)
Decisions from Diego: pages are **public to anyone with the link** (unlisted, no viewer login); sharing is **opt-in and off by default**; captions are on the video; the transcript sits beside it and downloads as **Markdown**, .txt, .srt or .vtt; the **view count** is shown in the app.

How v1 differs from the plan above:
- **No presigned URLs or R2 S3 keys.** The app uploads through the Worker in 16 MiB parts with the R2 binding's multipart API (each request stays under the 100 MB limit). The only secret is `UPLOAD_TOKEN`.
- **D1 instead of meta.json** for share metadata (title, duration, version) and the view counter (`UPDATE … views = views + 1` is atomic).
- **Views** are counted once per page load when playback starts, so Slack/iMessage link previews and bots don't count. They are not unique viewers.
- **Captions** are a WebVTT track that's on by default (crisp at any size; viewers can turn it off). They aren't burned into the pixels.
- **Updating a share** reuses the same link: the new video replaces the old one when the upload finishes.
- The page has a strict per-request nonce CSP, builds the transcript with `textContent` only, and sends `noindex`, `no-referrer` and `frame-ancestors 'none'`. Embedding will need that last one relaxed for `/embed/<id>`.

Files: `server/` (Worker, schema, wrangler.toml), `Sources/Tape/Sharing.swift` (Keychain config, `ShareClient`, `<name>.share.json`), the Share flow in `EditorWindow.swift`, `Caption.vtt`, and `Tape --share <video>` for testing.

Tested locally with `wrangler dev`:
- A 49 MB upload arrives byte for byte.
- Range requests return 206.
- `/api` without the token returns 401.
- HTML in titles and transcripts is escaped.
- All downloads work.
- Views count.
- The page was checked in Chrome: playback, captions, the highlighted line and the layout.

Not tested yet: the real deploy, Safari and phones, and the Share UI clicked through in the app.

### Next
- Deploy (`server/README.md`), then click through Share, Update and Stop Sharing in the app.
- Embed: an `/embed/<id>` player-only page, plus "Copy Embed Code" in the Shared menu.
- A poster image (the first frame) and `og:image` for link previews.
- Optional: unique viewers (a daily hashed cookie), or an expiry date per link.
