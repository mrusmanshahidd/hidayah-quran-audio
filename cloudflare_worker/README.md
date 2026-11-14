# Quran audio Cloudflare Worker

`hidayah-quran-audio` is a TypeScript replacement deployment target for the existing Dart audio API. It keeps Quran Foundation credentials and OAuth tokens on the server and returns audio metadata; the client downloads MP3 files directly from the supplied HTTPS CDN URL.

## API compatibility

| Request | Response |
| --- | --- |
| `GET /health` | `{ "status": "ok", "configured": true, "environment": "prelive" }` |
| `GET /api/quran/reciters` | `{ "reciters": [{ "id": 7, "reciterName": "…", "style": null }] }` |
| `GET /api/quran/audio/1:1?recitationId=7` | `{ "verseKey": "1:1", "recitationId": 7, "audioUrl": "https://…", "segments": [] }` |

The audio route includes the verse key in the path, as the Flutter repository and Dart backend already do. Errors use `{ "error": "…" }` with an HTTP status. There is no `/debug/qf` route. `/health` shows only configuration status and the selected environment.

The Worker uses the same prelive and production Quran Foundation OAuth and content API hosts as the Dart backend. It requests the `content` scope with client credentials, caches a token in each Worker isolate until shortly before expiry, and refreshes it after an upstream 401. It retries the content request once; a second 401 is returned as a generic error. No secret, token, Authorization header, or upstream response body is logged or returned.

## Local development

Install Node.js and npm on your own development machine if they are not already available. From this directory:

```powershell
npm install
Copy-Item .dev.vars.example .dev.vars
# Edit .dev.vars locally with your approved Quran Foundation credentials.
npm run typecheck
npm test
npm run dev
```

`.dev.vars` and `.env` are ignored by Git. Never commit them. Wrangler loads `.dev.vars` for local development. Check `http://localhost:8787/health`, then `/api/quran/reciters` and `/api/quran/audio/1:1?recitationId=7` (use an available recitation ID). Prelive may contain only a limited set of verses and reciters.

## Cloudflare deployment

1. In `wrangler.jsonc`, leave `QF_ENV` as `prelive` for prelive credentials or change it to `production` for approved production credentials. Keep the credentials and environment matched. The file contains no secret values.
2. From this directory, run `npm install`, `npm run typecheck`, and `npm test`.
3. Run `npx wrangler login` and then `npm run deploy`. Wrangler creates the Worker named `hidayah-quran-audio` and prints its HTTPS `workers.dev` URL. The first deployment will report `configured: false` until both secrets are set.
4. Run `npx wrangler secret put QF_CLIENT_ID` and enter the client ID at the prompt. Run `npx wrangler secret put QF_CLIENT_SECRET` and enter the secret at the prompt. These commands store encrypted Cloudflare Worker secrets and publish updated versions. [Cloudflare secret commands](https://developers.cloudflare.com/workers/wrangler/commands/workers/#secret)
5. Run `npm run deploy` once more to ensure the current source and configuration are deployed. Check `https://<your-worker-url>/health` for `configured: true`, then check `/api/quran/reciters` and `/api/quran/audio/1:1?recitationId=<available-id>`.
6. For GitHub deployment, commit only this source directory (excluding ignored files), connect the repository to Cloudflare Workers Builds, set the root directory to `server/quran_audio_worker`, build command to `npm run typecheck && npm test`, and deploy command to `npm run deploy`. Add both runtime secrets to the Worker in Cloudflare before enabling automatic deployments. Keep the non-secret settings in `wrangler.jsonc`.

Native Flutter Android does not require CORS. Browser requests from HTTP `localhost` and `127.0.0.1` origins are allowed. For a deployed browser app, set optional non-secret `QF_ALLOWED_ORIGINS` in `wrangler.jsonc` to a comma-separated list of exact HTTPS origins; other browser origins receive no CORS permission. The Worker uses `GET, OPTIONS` only and does not send wildcard CORS headers.

After deployment, Flutter needs only the Worker HTTPS base URL through its existing `AUDIO_API_BASE_URL` setting. No playback architecture or endpoint code change is needed.
