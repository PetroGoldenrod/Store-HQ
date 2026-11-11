# Store HQ

Back-office app for Goldenrod Shell (store 655675) and Trail Shell (store 654287).
Runs as a Cloudflare Worker (`closeout`) with a D1 database (`DB`).

## Layout
- `worker/worker.js` – the whole app (owner page, cashier page, manager login, APIs, nightly email). Deployed to the `closeout` Worker.
- `store-pc/vsupload.ps1` – nightly upload script that runs on each store PC (Task Scheduler, ~2 AM). Sends Verifone day reports, shift detail (LOGD logs) and a health report. Updates itself from the app (`/api/pc-script`).
- `tools/pollparse.mjs` – stand-alone copy of the Verifone transaction-log parser (also inlined in the worker) for testing.

## Deploying the worker
Cloudflare dashboard → Workers & Pages → closeout → Edit code → replace all with `worker/worker.js` → Deploy.
Secrets (OWNER_PASSWORD, PARTNER/MANAGER passwords, SSCS_TOKEN, GMAIL_APP_PASSWORD, ANTHROPIC_API_KEY) and the D1 binding live in Cloudflare, never in this repo.

## Never commit
Passwords, tokens, `token.txt`, or customer data.
