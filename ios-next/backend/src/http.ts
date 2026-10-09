import { badRequest, ApiError } from "./errors";
import type { Ctx } from "./context";

export async function readJson(c: Ctx): Promise<Record<string, unknown>> {
  let body: unknown;
  try {
    body = await c.req.json();
  } catch {
    throw badRequest("body must be JSON");
  }
  if (!body || typeof body !== "object" || Array.isArray(body)) throw badRequest("body must be a JSON object");
  return body as Record<string, unknown>;
}

export function str(body: Record<string, unknown>, key: string, opts: { max?: number; optional?: false }): string;
export function str(body: Record<string, unknown>, key: string, opts: { max?: number; optional: true }): string | undefined;
export function str(body: Record<string, unknown>, key: string, opts: { max?: number; optional?: boolean } = {}): string | undefined {
  const v = body[key];
  if (v === undefined || v === null || v === "") {
    if (opts.optional) return undefined;
    throw badRequest(`${key} is required`);
  }
  if (typeof v !== "string") throw badRequest(`${key} must be a string`);
  if (v.length > (opts.max ?? 4096)) throw badRequest(`${key} is too long`);
  return v;
}

/** Per-IP limit on a route group, when the rate-limit binding is present. */
export async function rateLimit(c: Ctx, group: string): Promise<void> {
  const limiter = c.env.AUTH_LIMITER;
  if (!limiter) return;
  const ip = c.req.header("cf-connecting-ip") ?? "unknown";
  const { success } = await limiter.limit({ key: `${group}:${ip}` });
  if (!success) throw new ApiError("rate_limited", "too many requests");
}

export function bearer(c: Ctx): string | undefined {
  const h = c.req.header("authorization");
  if (h?.toLowerCase().startsWith("bearer ")) return h.slice(7).trim();
  return undefined;
}
