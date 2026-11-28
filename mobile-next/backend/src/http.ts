// JSON responses, errors, and a tiny path router.

export class HttpError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message?: string,
  ) {
    super(message ?? code);
  }
}

export function json(body: unknown, status = 200, headers?: HeadersInit): Response {
  const h = new Headers(headers);
  h.set("content-type", "application/json; charset=utf-8");
  h.set("cache-control", "no-store");
  return new Response(JSON.stringify(body), { status, headers: h });
}

export function errorResponse(status: number, code: string, message?: string): Response {
  return json({ error: { code, message: message ?? code.replace(/_/g, " ") } }, status);
}

export async function readJson<T = Record<string, unknown>>(request: Request): Promise<T> {
  const text = await request.text();
  if (!text) return {} as T;
  try {
    const v = JSON.parse(text);
    if (v === null || typeof v !== "object" || Array.isArray(v)) throw new Error("not an object");
    return v as T;
  } catch {
    throw new HttpError(400, "invalid_json", "body must be a JSON object");
  }
}

export function requireString(
  body: Record<string, unknown>,
  key: string,
  opts: { max?: number; min?: number; optional?: false } = {},
): string {
  const v = body[key];
  if (typeof v !== "string") throw new HttpError(400, "invalid_request", `${key} is required`);
  const t = v.trim();
  if (t.length < (opts.min ?? 1) || t.length > (opts.max ?? 512))
    throw new HttpError(400, "invalid_request", `${key} has an invalid length`);
  return t;
}

export function optionalString(body: Record<string, unknown>, key: string, max = 512): string | null {
  const v = body[key];
  if (v === undefined || v === null) return null;
  if (typeof v !== "string") throw new HttpError(400, "invalid_request", `${key} must be a string`);
  const t = v.trim();
  if (t.length > max) throw new HttpError(400, "invalid_request", `${key} is too long`);
  return t || null;
}

export type Handler<C> = (ctx: C, params: Record<string, string>) => Promise<Response> | Response;

interface Route<C> {
  method: string;
  parts: string[];
  handler: Handler<C>;
}

export class Router<C> {
  private routes: Route<C>[] = [];

  on(method: string, path: string, handler: Handler<C>): this {
    this.routes.push({ method, parts: path.split("/").filter(Boolean), handler });
    return this;
  }

  /** Returns the handler for a request, a 405 marker, or null for 404. */
  match(
    method: string,
    pathname: string,
  ): { handler: Handler<C>; params: Record<string, string> } | "method_not_allowed" | null {
    const segs = pathname.split("/").filter(Boolean);
    let pathMatched = false;
    for (const r of this.routes) {
      if (r.parts.length !== segs.length) continue;
      const params: Record<string, string> = {};
      let ok = true;
      for (let i = 0; i < segs.length; i++) {
        const p = r.parts[i]!;
        const s = segs[i]!;
        if (p.startsWith(":")) params[p.slice(1)] = decodeURIComponent(s);
        else if (p !== s) {
          ok = false;
          break;
        }
      }
      if (!ok) continue;
      pathMatched = true;
      if (r.method === method) return { handler: r.handler, params };
    }
    return pathMatched ? "method_not_allowed" : null;
  }
}
