# Tape share server

A Cloudflare Worker that hosts shared Tape recordings on **your own** Cloudflare
account. Videos sit in a private R2 bucket and are only read through the Worker;
only Tape, with your upload token, can upload.

- `GET /recordings/<id>`: the public page. Anyone with the link can watch. Ids are
  12 random characters, the page is `noindex`, and there's no listing.
- `/api/*`: the owner API Tape uses. It needs `Authorization: Bearer <UPLOAD_TOKEN>`.
- Views are counted when someone presses play (link previews don't count).

Tape ships with no server: sharing stays off until you deploy your own and
enter its address and token in the app. With Claude Code, open this repo and ask
it to "set up sharing"; the `deploy-share-server` skill in `.claude/skills/` does
the steps below for you.

## Deploy (once, about 5 minutes)

You need Node 18+ and a free Cloudflare account. R2 must be turned on once in the
dashboard (R2 → Get started); Cloudflare may ask for a card even on the free tier.

```sh
cd server
npm install
npx wrangler login                          # opens the browser
npx wrangler r2 bucket create tape-shares
npx wrangler d1 create tape                 # put the database_id it prints in wrangler.toml
npm run db:init
TOKEN=$(openssl rand -base64 32 | tr -d '=+/'); echo "$TOKEN"   # your upload token; keep it
printf %s "$TOKEN" | npx wrangler secret put UPLOAD_TOKEN
npx wrangler deploy                         # prints https://tape.<you>.workers.dev
```

Then connect Tape: open a recording, click **Share…**, and enter the URL and the
token. Or from the terminal:

```sh
TAPE_SERVER=https://tape.<you>.workers.dev TAPE_TOKEN=$TOKEN \
  /Applications/Tape.app/Contents/MacOS/Tape --configure-sharing
```

Share links look like `https://tape.<you>.workers.dev/recordings/<id>`.

## Your own domain (optional)

Add a custom domain under Workers & Pages → tape → Settings → Domains & Routes
(the domain must be on Cloudflare). To serve under a path of a site you already
run, set `BASE_PATH` (e.g. `"/tape"`) and enter `https://example.com/tape` as the
server in Tape. Keep such settings out of git: copy `wrangler.toml` to
`wrangler.local.toml` (ignored) and deploy with `npx wrangler deploy -c wrangler.local.toml`.

## Local development

```sh
npm run db:init:local
echo 'UPLOAD_TOKEN=dev-token-change-me' > .dev.vars   # git-ignored
npm run dev                                           # http://localhost:8787
TAPE_SERVER=http://localhost:8787 TAPE_TOKEN=dev-token-change-me \
  /Applications/Tape.app/Contents/MacOS/Tape --share <video>
```

## Cost

R2 has no egress fees, so views are free. Storage is free up to 10 GB, then
about $0.015/GB a month. Workers and D1 stay within the free tier for personal
use. Check Cloudflare's pricing pages for current numbers.
