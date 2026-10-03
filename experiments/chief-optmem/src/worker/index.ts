import type { Env } from "./env.ts";

export { MemoryDO } from "./memory-do.ts";

const ID = /^[a-z0-9_-]{1,64}$/;

const json = (value: unknown, status = 200) =>
  new Response(JSON.stringify(value), { status, headers: { "content-type": "application/json; charset=utf-8" } });

const isStrings = (v: unknown): v is Array<string> => Array.isArray(v) && v.every((s) => typeof s === "string");
const optionalString = (v: unknown): v is string | undefined =>
  v === undefined || (typeof v === "string" && v.length <= 200);

/** Constant-time comparison of the bearer token. */
function authorized(request: Request, env: Env): boolean {
  const got = new TextEncoder().encode(request.headers.get("authorization") ?? "");
  const want = new TextEncoder().encode(`Bearer ${env.CHIEF_TOKEN}`);
  if (!env.CHIEF_TOKEN || got.length !== want.length) return false;
  let diff = 0;
  for (let i = 0; i < got.length; i++) diff |= got[i]! ^ want[i]!;
  return diff === 0;
}

async function body(request: Request): Promise<Record<string, unknown>> {
  try {
    const v: unknown = await request.json();
    return v !== null && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : {};
  } catch {
    return {};
  }
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/healthz") return json({ ok: true, environment: env.ENVIRONMENT });
    if (!url.pathname.startsWith("/v1/")) return json({ error: "not_found" }, 404);
    if (!authorized(request, env)) return json({ error: "unauthorized" }, 401);

    const m = /^\/v1\/memories\/([^/]+)\/(memo|note|view|timezone)$/.exec(url.pathname);
    if (!m || !ID.test(m[1]!)) return json({ error: "not_found" }, 404);
    const memory = env.MEMORY_DO.get(env.MEMORY_DO.idFromName(`memory:${m[1]}`));
    const route = `${request.method} ${m[2]}`;

    if (route === "GET view") return json(await memory.view());
    const b = await body(request);
    switch (route) {
      case "POST memo": {
        if (!isStrings(b.argv) || b.argv.length === 0 || !optionalString(b.key)) return json({ error: "invalid" }, 400);
        const files = b.files !== null && typeof b.files === "object" ? (b.files as Record<string, string>) : undefined;
        const options = { ...(b.key === undefined ? {} : { key: b.key }), ...(files ? { files } : {}) };
        return json(await memory.memo(b.argv, options));
      }
      case "POST note": {
        if (!isStrings(b.texts) || b.texts.length === 0 || b.texts.length > 1000 || !optionalString(b.key)) {
          return json({ error: "invalid" }, 400);
        }
        const result = await memory.note(b.texts, b.key);
        return json(result, "error" in result ? 400 : 200);
      }
      case "PUT timezone": {
        if (typeof b.tz !== "string") return json({ error: "invalid" }, 400);
        try {
          return json(await memory.setTimeZone(b.tz));
        } catch {
          return json({ error: "invalid_time_zone" }, 400);
        }
      }
      default:
        return json({ error: "method_not_allowed" }, 405);
    }
  },
} satisfies ExportedHandler<Env>;
