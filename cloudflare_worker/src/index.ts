export interface Env {
  QF_CLIENT_ID?: string;
  QF_CLIENT_SECRET?: string;
  QF_ENV?: string;
  QF_ALLOWED_ORIGINS?: string;
}

type QfEnvironment = "prelive" | "production";
type JsonObject = Record<string, unknown>;
type Fetcher = typeof fetch;

const UNAVAILABLE = "Quran audio service is currently unavailable.";
const AUTH_BASE: Record<QfEnvironment, string> = {
  prelive: "https://prelive-oauth2.quran.foundation",
  production: "https://oauth2.quran.foundation",
};
const API_BASE: Record<QfEnvironment, string> = {
  prelive: "https://apis-prelive.quran.foundation",
  production: "https://apis.quran.foundation",
};

class ApiFailure extends Error {
  constructor(readonly status: number, message: string) {
    super(message);
  }
}

function environment(env: Env): QfEnvironment | null {
  const value = env.QF_ENV ?? "prelive";
  return value === "prelive" || value === "production" ? value : null;
}

function configured(env: Env): boolean {
  return Boolean(
    environment(env) &&
    env.QF_CLIENT_ID?.trim() &&
    env.QF_CLIENT_SECRET?.trim() &&
    !env.QF_CLIENT_ID?.startsWith("your-") &&
    !env.QF_CLIENT_SECRET?.startsWith("your-"),
  );
}

function object(value: unknown): value is JsonObject {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  });
}

function corsHeaders(request: Request, env: Env): Headers {
  const headers = new Headers();
  const origin = request.headers.get("Origin");
  if (origin === null) return headers;
  headers.set("Vary", "Origin");
  let parsed: URL;
  try {
    parsed = new URL(origin);
  } catch {
    return headers;
  }
  if (origin !== parsed.origin) return headers;
  const local = parsed.protocol === "http:" &&
    (parsed.hostname === "localhost" || parsed.hostname === "127.0.0.1");
  const allowed = parsed.protocol === "https:" &&
    (env.QF_ALLOWED_ORIGINS ?? "").split(",").some((entry) => entry.trim() === origin);
  if (local || allowed) {
    headers.set("Access-Control-Allow-Origin", origin);
    headers.set("Access-Control-Allow-Methods", "GET, OPTIONS");
  }
  return headers;
}

function withCors(response: Response, headers: Headers): Response {
  for (const [key, value] of headers) response.headers.set(key, value);
  return response;
}

function audioUrl(value: string): string | null {
  try {
    const url = value.startsWith("//")
      ? new URL(`https:${value}`)
      : new URL(value, "https://audio.qurancdn.com/");
    if (url.protocol !== "https:" || !url.hostname || url.username || url.password) return null;
    return url.toString();
  } catch {
    return null;
  }
}

// One handler per isolate keeps its cache private. A new isolate simply fetches a new token.
export function createWorker(upstreamFetch: Fetcher = fetch) {
  let token: string | null = null;
  let expiresAt = 0;
  let pendingToken: Promise<string> | null = null;
  let cacheId: string | undefined;
  let cacheSecret: string | undefined;
  let cacheEnvironment: QfEnvironment | null = null;

  function resetForBindings(env: Env, target: QfEnvironment): void {
    if (cacheId !== env.QF_CLIENT_ID || cacheSecret !== env.QF_CLIENT_SECRET || cacheEnvironment !== target) {
      token = null;
      expiresAt = 0;
      pendingToken = null;
      cacheId = env.QF_CLIENT_ID;
      cacheSecret = env.QF_CLIENT_SECRET;
      cacheEnvironment = target;
    }
  }

  async function fetchToken(env: Env, target: QfEnvironment): Promise<string> {
    let response: Response;
    try {
      const credentials = new TextEncoder().encode(`${env.QF_CLIENT_ID}:${env.QF_CLIENT_SECRET}`);
      const basic = btoa(String.fromCharCode(...credentials));
      response = await upstreamFetch(`${AUTH_BASE[target]}/oauth2/token`, {
        method: "POST",
        headers: {
          Authorization: `Basic ${basic}`,
          "Content-Type": "application/x-www-form-urlencoded",
        },
        body: "grant_type=client_credentials&scope=content",
        signal: AbortSignal.timeout(12_000),
      });
    } catch {
      throw new ApiFailure(503, UNAVAILABLE);
    }
    if (response.status !== 200) throw new ApiFailure(response.status, UNAVAILABLE);
    let data: unknown;
    try {
      data = await response.json();
    } catch {
      throw new ApiFailure(502, "Invalid audio authentication response.");
    }
    if (!object(data) || typeof data.access_token !== "string" || !data.access_token ||
        typeof data.expires_in !== "number" || !Number.isFinite(data.expires_in) || data.expires_in <= 0) {
      throw new ApiFailure(502, "Invalid audio authentication response.");
    }
    token = data.access_token;
    expiresAt = Date.now() + Math.max(0, Math.floor(data.expires_in) - (data.expires_in > 60 ? 60 : 1)) * 1000;
    return token;
  }

  async function accessToken(env: Env, target: QfEnvironment): Promise<string> {
    if (!configured(env)) throw new ApiFailure(503, "Audio service is not configured.");
    resetForBindings(env, target);
    if (token && Date.now() < expiresAt) return token;
    if (!pendingToken) {
      const request = fetchToken(env, target);
      pendingToken = request;
      void request.finally(() => { if (pendingToken === request) pendingToken = null; }).catch(() => {});
    }
    return pendingToken;
  }

  async function content(env: Env, target: QfEnvironment, path: string): Promise<JsonObject> {
    for (let attempt = 0; attempt < 2; attempt++) {
      const usedToken = await accessToken(env, target);
      let response: Response;
      try {
        response = await upstreamFetch(`${API_BASE[target]}${path}`, {
          headers: {
            "x-auth-token": usedToken,
            "x-client-id": env.QF_CLIENT_ID!,
            Accept: "application/json",
          },
          signal: AbortSignal.timeout(12_000),
        });
      } catch {
        throw new ApiFailure(503, UNAVAILABLE);
      }
      if (response.status === 401 && attempt === 0) {
        if (token === usedToken) { token = null; expiresAt = 0; }
        continue;
      }
      if (response.status !== 200) throw new ApiFailure(response.status, UNAVAILABLE);
      let data: unknown;
      try {
        data = await response.json();
      } catch {
        throw new ApiFailure(502, "Invalid Quran audio response.");
      }
      if (!object(data)) throw new ApiFailure(502, "Invalid Quran audio response.");
      return data;
    }
    throw new ApiFailure(502, UNAVAILABLE);
  }

  async function reciters(env: Env, target: QfEnvironment): Promise<JsonObject> {
    const data = await content(env, target, "/content/api/v4/resources/recitations");
    if (!Array.isArray(data.recitations)) throw new ApiFailure(502, "Invalid reciter response.");
    const rows = data.recitations.flatMap((row: unknown) => {
      if (!object(row) || typeof row.id !== "number" || !Number.isInteger(row.id) || row.id <= 0 ||
          (typeof row.reciter_name !== "string" && !object(row.translated_name))) return [];
      const translated = object(row.translated_name) ? row.translated_name.name : null;
      return [{
        id: row.id,
        reciterName: typeof translated === "string" ? translated : (row.reciter_name ?? null),
        style: typeof row.style === "string" ? row.style : null,
      }];
    });
    return { reciters: rows };
  }

  async function verseAudio(env: Env, target: QfEnvironment, verseKey: string, recitationId: number): Promise<JsonObject> {
    const data = await content(env, target,
      `/content/api/v4/recitations/${recitationId}/by_ayah/${verseKey}?fields=segments`);
    if (!Array.isArray(data.audio_files)) throw new ApiFailure(502, "Invalid Quran audio response.");
    for (const file of data.audio_files) {
      if (!object(file) || file.verse_key !== verseKey) continue;
      if (typeof file.url !== "string" || !file.url) break;
      const url = audioUrl(file.url);
      if (!url) break;
      return {
        verseKey,
        recitationId,
        audioUrl: url,
        segments: Array.isArray(file.segments) ? file.segments : [],
      };
    }
    throw new ApiFailure(404, "Audio is unavailable for this Ayah.");
  }

  return {
    async fetch(request: Request, env: Env): Promise<Response> {
      const cors = corsHeaders(request, env);
      if (request.method === "OPTIONS" && cors.has("Access-Control-Allow-Origin")) {
        return withCors(new Response(null, { status: 204 }), cors);
      }
      try {
        if (request.method !== "GET") throw new ApiFailure(405, "Method not allowed.");
        const url = new URL(request.url);
        const target = environment(env);
        if (url.pathname === "/health") {
          return withCors(json({
            status: "ok",
            configured: configured(env),
            environment: target ?? "invalid",
          }), cors);
        }
        if (!target) throw new ApiFailure(503, "Audio service is not configured.");
        if (url.pathname === "/api/quran/reciters") {
          return withCors(json(await reciters(env, target)), cors);
        }
        const match = /^\/api\/quran\/audio\/([^/]+)$/.exec(url.pathname);
        if (match) {
          const verseKey = decodeURIComponent(match[1]);
          const idText = url.searchParams.get("recitationId") ?? "";
          const id = Number(idText);
          if (!/^[1-9]\d{0,2}:[1-9]\d{0,2}$/.test(verseKey) ||
              !/^[1-9]\d*$/.test(idText) || !Number.isSafeInteger(id)) {
            throw new ApiFailure(400, "Valid verseKey and recitationId are required.");
          }
          return withCors(json(await verseAudio(env, target, verseKey, id)), cors);
        }
        throw new ApiFailure(404, "Endpoint not found.");
      } catch (error) {
        const failure = error instanceof ApiFailure ? error : new ApiFailure(502, UNAVAILABLE);
        return withCors(json({ error: failure.message }, failure.status), cors);
      }
    },
  };
}

export default createWorker();
