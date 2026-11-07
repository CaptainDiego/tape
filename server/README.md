# Tape share server

A Cloudflare Worker that hosts shared Tape recordings. It's yours: the videos
sit in your own private R2 bucket, and only Tape (with your token) can upload.

- `GET /v/<id>`: the public page. Anyone with the link can watch; ids are 12
  random characters, the page is `noindex`, and there's no listing.
- `/api/*`: the owner API Tape uses. It needs `Authorization: Bearer <UPLOAD_TOKEN>`.
- Views are counted when someone presses play (link previews don't count).

Tape ships with no server: sharing stays off until you deploy your own and
enter its URL and token in the app. With Claude Code, open this repo and ask it
to "deploy the share server". The `deploy-share-server` skill in
`.claude/skills/` walks through the steps below.

## Deploy (once, about 5 minutes)

```sh
cd server
npm install
npx wrangler login                          # opens the browser
npx wrangler r2 bucket create tape-shares
npx wrangler d1 create tape                 # copy the database_id it prints into wrangler.toml
npm run db:init
openssl rand -base64 32 | tr -d '=+/'       # this is your token; keep it
npx wrangler secret put UPLOAD_TOKEN        # paste the token
npx wrangler deploy                         # prints https://tape.<you>.workers.dev
```

Then, in Tape, open a recording, click **Share…**, and enter the URL and the token.

Optional: add a custom domain such as `tape.example.com` under
Workers & Pages → tape → Settings → Domains & Routes.

## Local development

```sh
npm run db:init:local
npm run dev                                 # http://localhost:8787, token from .dev.vars
```

`.dev.vars` holds a development token (git-ignored). Test an upload without the
app UI: `TAPE_SERVER=http://localhost:8787 TAPE_TOKEN=dev-token-change-me Tape --share <video>`.

## Cost

R2 has no egress fees, so views are free. Storage is free up to 10 GB, then
about $0.015/GB a month. Workers and D1 stay within the free tier for personal
use. Check Cloudflare's pricing pages for current numbers.
