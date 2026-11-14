import { afterEach, describe, expect, it, vi } from "vitest";
import { createWorker, type Env } from "../src/index";

const env: Env = { QF_CLIENT_ID: "test-id", QF_CLIENT_SECRET: "test-secret", QF_ENV: "prelive" };
const request = (path: string, origin?: string) => new Request(`https://worker.example.test${path}`, {
  headers: origin ? { Origin: origin } : undefined,
});
const token = (value = "test-token") => Response.json({ access_token: value, expires_in: 3600 });

afterEach(() => vi.restoreAllMocks());

describe("Quran audio Worker", () => {
  it("reports health and fails safely without credentials", async () => {
    const upstream = vi.fn<typeof fetch>();
    const worker = createWorker(upstream);
    const missing = { QF_ENV: "production" };
    expect(await (await worker.fetch(request("/health"), missing)).json()).toEqual({
      status: "ok", configured: false, environment: "production",
    });
    const response = await worker.fetch(request("/api/quran/reciters"), missing);
    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ error: "Audio service is not configured." });
    expect(upstream).not.toHaveBeenCalled();
  });

  it("uses Basic client credentials, caches the token, and returns compatible reciters", async () => {
    const upstream = vi.fn<typeof fetch>().mockImplementation(async (input, init) => {
      if (String(input).endsWith("/oauth2/token")) {
        expect(String(input)).toBe("https://prelive-oauth2.quran.foundation/oauth2/token");
        expect(init?.method).toBe("POST");
        expect(new Headers(init?.headers).get("Authorization")).toBe("Basic dGVzdC1pZDp0ZXN0LXNlY3JldA==");
        expect(init?.body).toBe("grant_type=client_credentials&scope=content");
        return token();
      }
      expect(String(input)).toBe("https://apis-prelive.quran.foundation/content/api/v4/resources/recitations");
      expect(new Headers(init?.headers).get("x-auth-token")).toBe("test-token");
      expect(new Headers(init?.headers).get("x-client-id")).toBe("test-id");
      return Response.json({ recitations: [
        { id: 7, reciter_name: "Original", translated_name: { name: "Translated" }, style: "Murattal" },
        { id: 0, reciter_name: "Invalid" },
      ] });
    });
    const worker = createWorker(upstream);
    for (let i = 0; i < 2; i++) {
      const response = await worker.fetch(request("/api/quran/reciters"), env);
      expect(response.status).toBe(200);
      expect(await response.json()).toEqual({ reciters: [
        { id: 7, reciterName: "Translated", style: "Murattal" },
      ] });
    }
    expect(upstream).toHaveBeenCalledTimes(3);
  });

  it("uses production OAuth and API hosts for production bindings", async () => {
    const upstream = vi.fn<typeof fetch>().mockImplementation(async (input) => {
      if (String(input) === "https://oauth2.quran.foundation/oauth2/token") return token();
      expect(String(input)).toBe("https://apis.quran.foundation/content/api/v4/resources/recitations");
      return Response.json({ recitations: [] });
    });
    const response = await createWorker(upstream).fetch(request("/api/quran/reciters"), {
      ...env, QF_ENV: "production",
    });
    expect(response.status).toBe(200);
    expect(upstream).toHaveBeenCalledTimes(2);
  });

  it("returns verse metadata with a direct HTTPS CDN URL", async () => {
    const upstream = vi.fn<typeof fetch>().mockImplementation(async (input) => {
      if (String(input).endsWith("/oauth2/token")) return token();
      expect(String(input)).toBe("https://apis-prelive.quran.foundation/content/api/v4/recitations/7/by_ayah/1:1?fields=segments");
      return Response.json({ audio_files: [
        { verse_key: "1:1", url: "recitations/7/1.mp3", segments: [[0, 1000]] },
      ] });
    });
    const response = await createWorker(upstream).fetch(request("/api/quran/audio/1:1?recitationId=7"), env);
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      verseKey: "1:1", recitationId: 7,
      audioUrl: "https://audio.qurancdn.com/recitations/7/1.mp3", segments: [[0, 1000]],
    });
    expect(upstream).toHaveBeenCalledTimes(2);
  });

  it("refreshes on the first 401 and retries exactly once", async () => {
    let tokens = 0;
    let contentCalls = 0;
    const upstream = vi.fn<typeof fetch>().mockImplementation(async (input, init) => {
      if (String(input).endsWith("/oauth2/token")) return token(`token-${++tokens}`);
      expect(new Headers(init?.headers).get("x-auth-token")).toBe(`token-${++contentCalls}`);
      return contentCalls === 1
        ? new Response("denied", { status: 401 })
        : Response.json({ recitations: [{ id: 7, reciter_name: "Test" }] });
    });
    const response = await createWorker(upstream).fetch(request("/api/quran/reciters"), env);
    expect(response.status).toBe(200);
    expect(tokens).toBe(2);
    expect(contentCalls).toBe(2);
  });

  it("stops after the second 401 and never echoes secrets or tokens", async () => {
    let tokens = 0;
    let contentCalls = 0;
    const upstream = vi.fn<typeof fetch>().mockImplementation(async (input) => {
      if (String(input).endsWith("/oauth2/token")) { tokens++; return token("sensitive-token"); }
      contentCalls++;
      return new Response("test-secret sensitive-token Authorization: Basic secret", { status: 401 });
    });
    const response = await createWorker(upstream).fetch(request("/api/quran/reciters"), env);
    expect(response.status).toBe(401);
    const body = await response.text();
    expect(JSON.parse(body)).toEqual({ error: "Quran audio service is currently unavailable." });
    expect(body).not.toMatch(/test-secret|sensitive-token|Authorization|Basic/);
    expect(tokens).toBe(2);
    expect(contentCalls).toBe(2);
  });

  it("validates the route and only allows local or configured browser origins", async () => {
    const worker = createWorker(vi.fn<typeof fetch>());
    expect((await worker.fetch(request("/api/quran/audio/bad?recitationId=7"), env)).status).toBe(400);
    expect((await worker.fetch(request("/health", "http://localhost:62656"), env))
      .headers.get("Access-Control-Allow-Origin")).toBe("http://localhost:62656");
    expect((await worker.fetch(request("/health", "https://example.com"), env))
      .headers.get("Access-Control-Allow-Origin")).toBeNull();
    const allowed = { ...env, QF_ALLOWED_ORIGINS: "https://app.example.test" };
    expect((await worker.fetch(request("/health", "https://app.example.test"), allowed))
      .headers.get("Access-Control-Allow-Origin")).toBe("https://app.example.test");
    const preflight = await worker.fetch(new Request("https://worker.example.test/api/quran/reciters", {
      method: "OPTIONS", headers: { Origin: "https://app.example.test" },
    }), allowed);
    expect(preflight.status).toBe(204);
    expect((await worker.fetch(request("/debug/qf"), env)).status).toBe(404);
  });
});
