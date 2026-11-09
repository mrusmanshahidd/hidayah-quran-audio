# Quran audio backend

This Dart server keeps Quran Foundation credentials outside the Android app.
Copy `.env.example` to `.env` in this directory and replace the placeholders
with your approved backend client credentials. `.env` is ignored by Git.
Prelive is the default environment and contains only Surahs 1 and 2.

From the project root, run:

```powershell
cd server/quran_audio
dart pub get
dart run bin/server.dart
```

Check `http://localhost:8080/health`, then
`http://localhost:8080/debug/qf`, then
`http://localhost:8080/api/quran/reciters`. The debug endpoint is available
only for loopback requests in prelive. It checks the token, authenticated
`/content/api/v4/chapters`, and ayah-recitation catalog in that order. The
server logs upstream status, error type, message, environment, and path without
logging credentials or tokens. If the token endpoint returns `invalid_scope`,
check the scopes approved for this client in Developer Console and set
`QF_SCOPE` to those scopes in `.env`; `content` remains the default.

For an Android phone on the same
Wi-Fi, use the PC's LAN IPv4 address when launching the debug app:

```powershell
flutter run --dart-define=AUDIO_API_BASE_URL=http://YOUR_PC_LAN_IP:8080
```

The server listens on all IPv4 interfaces by default. Permit inbound TCP 8080
in your local firewall if the phone cannot reach `/health`. Only debug Android
builds permit cleartext HTTP; use HTTPS for a deployed backend.

## Docker deployment

Build the Docker service from `server/quran_audio` using its `Dockerfile`. The
image compiles the server with `QF_PRODUCTION_BUILD=true`: it never reads `.env`,
and `/debug/qf` is unavailable even when `QF_ENV=prelive`. The `.dockerignore`
also excludes `.env` from the build context. The server keeps Quran Foundation
credentials, cached tokens, and the single retry on upstream 401 server-side.

1. Deploy the Docker service to a Docker-compatible host.
2. Set `QF_CLIENT_ID` in the hosting environment.
3. Set `QF_CLIENT_SECRET` in the hosting environment as a secret.
4. Set `QF_ENV=production` for approved production credentials, or `QF_ENV=prelive` for prelive credentials. Keep credentials and environment matched.
5. Let the provider supply `PORT`; the server listens on that port, defaulting to 8080 if absent. `EXPOSE 8080` documents the default only.
6. Configure a hosting health check for `GET /health` and verify HTTP 200. Its JSON contains no credentials or tokens.
7. Verify `GET /api/quran/reciters` over HTTPS.
8. Use the deployed HTTPS URL in Flutter, for example `--dart-define=AUDIO_API_BASE_URL=https://<deployed-service>`.

After deployment the provider will give a URL such as
`https://<deployed-service>`; replace that placeholder with the actual URL.
Do not put credentials or `.env` in the image. `QF_SCOPE` is optional when the
approved scope differs from the default `content`.

For browser clients, optionally set `QF_ALLOWED_ORIGINS` to a comma-separated
list of exact HTTPS web origins (for example, the origin of your deployed web
app). Production sends CORS headers only for those origins. Development keeps
HTTP `localhost` and `127.0.0.1` origins available. Native Android requests do
not require CORS headers. Leave `QF_ALLOWED_ORIGINS` empty if only native clients
will access the service.
