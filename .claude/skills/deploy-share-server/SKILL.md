---
name: deploy-share-server
description: Deploy Tape's share server (server/) to the user's own Cloudflare account and connect the Tape app to it. Use when the user wants to set up sharing, deploy the share server, get share links working, or move sharing to another Cloudflare account.
---

# Deploy Tape's share server

Tape's sharing is optional and self-hosted: each person runs `server/` on
**their own** Cloudflare account and enters its URL and an upload token in the
app. There is no shared or default server. Never point a user at someone else's
deployment.

The server is one Worker, one private R2 bucket (`tape-shares`) and one D1
database (`tape`). It all fits in Cloudflare's free tier for personal use.

## Steps

Work in `server/`. Show the user what each step does before running it.

1. **Prerequisites.** Check `node --version` (18 or newer). Run `npm install`.
2. **Log in.** Ask the user to run `! npx wrangler login`, which opens a browser
   to sign in to Cloudflare. Don't log in for them. Confirm with `npx wrangler whoami`.
   If they don't have an account, they sign up at dash.cloudflare.com first (free).
3. **R2.** Run `npx wrangler r2 bucket create tape-shares`. If R2 isn't enabled,
   the user turns it on once in the dashboard (R2 → Get started). It can ask for
   a card even on the free tier. Let the user do that themselves.
   If the bucket already exists, reuse it.
4. **D1.** Run `npx wrangler d1 create tape`. Put the `database_id` it prints into
   `wrangler.toml`, replacing the placeholder. If `tape` already exists, get its id
   from `npx wrangler d1 list`. Then run `npm run db:init`.
5. **Token.** Generate one with `openssl rand -base64 32 | tr -d '=+/'` and set it
   with `npx wrangler secret put UPLOAD_TOKEN`, piping it in
   (`printf %s "$TOKEN" | npx wrangler secret put UPLOAD_TOKEN`).
   Don't write the token to any file in the repo. Show it to the user once, so they
   can paste it into Tape and keep it in their password manager.
6. **Deploy.** Run `npx wrangler deploy` and note the `https://tape.<subdomain>.workers.dev` URL.
7. **Verify:**
   - `curl -s -o /dev/null -w '%{http_code}' -X POST <url>/api/shares` → `401` (the API is locked).
   - `curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOKEN" <url>/api/shares/000000000000` → `404` (the token works).
8. **Connect the app.** In Tape, open a recording, click **Share…** (⇧⌘S), and
   enter the URL and the token. Tape checks them and keeps the token in the Keychain.
   To test without the UI:
   `TAPE_SERVER=<url> TAPE_TOKEN=$TOKEN Tape --share <video>`
   (`Tape` is `/Applications/Tape.app/Contents/MacOS/Tape`).

## Optional
- **Custom domain:** in the dashboard, Workers & Pages → tape → Settings →
  Domains & Routes. The domain must be on Cloudflare.
- **New token:** run `secret put` again, then update it in Tape's Sharing
  Settings. Existing links keep working.

## Don't
- Don't commit `.dev.vars`, tokens, or account ids beyond `database_id` in `wrangler.toml`.
- Don't make the bucket public or turn on `r2.dev` access. Everything is read through the Worker.
- Don't add accounts or a viewer login. Pages are public to anyone with the link by design.
