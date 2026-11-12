---
name: deploy-share-server
description: Set up Tape's optional sharing — deploy the share server (server/) to the user's own Cloudflare account (Worker + R2 bucket + D1 database), connect the Tape app to it, and check that a share link works. Use when the user wants to set up sharing, deploy the share server, get share links working, fix a broken share setup, or move sharing to another Cloudflare account.
---

# Set up Tape's share server

Tape's sharing is self-hosted: each person runs `server/` on **their own**
Cloudflare account. There is no shared or default server; never point a user at
someone else's deployment. The server is one Worker (`tape`), one private R2
bucket (`tape-shares`) and one D1 database (`tape`), and fits in Cloudflare's
free tier for personal use. The result is share links like
`https://tape.<subdomain>.workers.dev/recordings/<id>`.

Work in `server/`. Before each step, say in one line what it does. Commands that
need the user (logging in, the dashboard) are theirs to run; don't do them for
them.

## Steps

1. **Prerequisites.**
   - `node --version` must be 18 or newer; if Node is missing, tell the user to install it (nodejs.org or `brew install node`) and stop.
   - Tape must be installed: `/Applications/Tape.app/Contents/MacOS/Tape` exists. If not, build it from the repo root with `./build.sh --install` (warn first that it resets Tape's privacy permissions).
   - Run `npm install`.

2. **Log in to Cloudflare.** Ask the user to type `! npx wrangler login` (it opens the browser). If they have no account, they sign up free at dash.cloudflare.com first. Confirm with `npx wrangler whoami`. If it lists several accounts, ask which one and use `CLOUDFLARE_ACCOUNT_ID=<id>` on every later wrangler command.

3. **Local config.** Copy `wrangler.toml` to `wrangler.local.toml` (git-ignored) and use `-c wrangler.local.toml` on every deploy, so the user's database id never lands in git. If `wrangler.local.toml` already exists, reuse it and read what it says rather than overwriting it.

4. **R2.** Run `npx wrangler r2 bucket create tape-shares`.
   - "Please enable R2 through the Cloudflare Dashboard" (code 10042): the user turns R2 on once at dash.cloudflare.com → R2 → Get started (it may ask for a card even on the free tier). Wait for them, then retry.
   - "already exists": fine, reuse it.

5. **D1.** Run `npx wrangler d1 create tape` and put the `database_id` it prints into `wrangler.local.toml`, replacing `REPLACE_WITH_YOUR_D1_DATABASE_ID`. If `tape` already exists, get its id from `npx wrangler d1 list`. Then create the table: `npx wrangler d1 execute tape --remote --file schema.sql -c wrangler.local.toml`.

6. **Deploy.** Run `npx wrangler deploy -c wrangler.local.toml` and take the `https://tape.<subdomain>.workers.dev` URL from its output.
   - If it says the account has no workers.dev subdomain, the user picks one once in the dashboard (Workers & Pages → the subdomain prompt, or Settings → Subdomain), then deploy again.
   - A brand-new workers.dev subdomain can take a minute or two to start answering; retry the check below before assuming it's broken.

7. **Token, server and app in one command.** Shell state doesn't carry between commands, so generate the token, store it as the Worker secret and save it in Tape in a single command, without writing it to any file:
   ```sh
   TOKEN=$(openssl rand -base64 32 | tr -d '=+/') &&
   printf %s "$TOKEN" | npx wrangler secret put UPLOAD_TOKEN -c wrangler.local.toml &&
   TAPE_SERVER=<url> TAPE_TOKEN="$TOKEN" /Applications/Tape.app/Contents/MacOS/Tape --configure-sharing &&
   echo "Your upload token (save it in your password manager): $TOKEN"
   ```
   `--configure-sharing` stores the server in Tape's settings and the token in the Keychain, exactly like the Share dialog. Show the user the token once; never write it to a file in the repo. If Tape is running, it picks the settings up on the next Share.

8. **Check it works.**
   - `curl -s -o /dev/null -w '%{http_code}\n' -X POST <url>/api/shares` → `401` (the API is locked).
   - `curl -s -o /dev/null -w '%{http_code}\n' <url>/recordings/000000000000` → `404` (the Worker answers).
   - Optional end-to-end test, only if the user agrees (it uploads one recording): ask them to open a short recording in Tape and click **Share…**. The link is copied; open it to confirm the page plays, then use **Shared ▾ → Stop Sharing…** if it was only a test.

9. **Tell the user how to share:** open a recording in Tape, click **Share…** (⇧⌘S), confirm the upload, and the link is copied. **Shared ▾** shows views and can update or delete the link. The first Share after each new build of Tape may show a Keychain prompt; **Always Allow**.

## Optional
- **Custom domain:** Workers & Pages → tape → Settings → Domains & Routes (the domain must be on Cloudflare). Then run `--configure-sharing` again with the new address (or change it in Tape's Sharing Settings). Existing links on the old address keep working only as long as that address does.
- **Serving under a path** of a site the user already has: set `BASE_PATH = "/tape"` in `wrangler.local.toml`, route the path to this Worker, and use `https://example.com/tape` as the server.
- **New token:** repeat step 7. Existing links keep working.
- **Remove everything:** `npx wrangler delete -c wrangler.local.toml`, `npx wrangler r2 bucket delete tape-shares` (empty it first in the dashboard), `npx wrangler d1 delete tape`. Only when the user asks; it breaks every link.

## Don't
- Don't commit `wrangler.local.toml`, `.dev.vars`, tokens or account ids.
- Don't make the bucket public or turn on `r2.dev` access. Everything is read through the Worker.
- Don't add viewer accounts or a login. Pages are public to anyone with the link by design.
- Don't point Tape at any server except the one deployed in this session (or one the user names as their own).
