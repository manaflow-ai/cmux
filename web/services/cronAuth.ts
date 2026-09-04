import { timingSafeEqual } from "node:crypto";

/**
 * Shared authentication for cron-triggered routes (Vercel Cron and any
 * operator-driven caller): a `Authorization: Bearer <CRON_SECRET>` header,
 * compared in constant time.
 *
 * Every cron route is publicly reachable; the secret is the only gate, so the
 * comparison must not leak it through timing the way a plain string `!==` on
 * the header does. The result names the failure instead of building a
 * Response, because routes deliberately differ in how they answer a missing
 * `CRON_SECRET` (401 vs 503); both are fail-closed.
 */
export type CronAuthResult =
  | { readonly ok: true }
  | {
    readonly ok: false;
    readonly reason: "cron_secret_missing" | "unauthorized";
  };

export function authorizeCronRequest(request: Request): CronAuthResult {
  const secret = process.env.CRON_SECRET?.trim();
  if (!secret) return { ok: false, reason: "cron_secret_missing" };
  const authorization = request.headers.get("authorization")?.trim() ?? "";
  const token = authorization.toLowerCase().startsWith("bearer ")
    ? authorization.slice("bearer ".length).trim()
    : "";
  const tokenBytes = Buffer.from(token);
  const secretBytes = Buffer.from(secret);
  const matches =
    tokenBytes.length === secretBytes.length &&
    timingSafeEqual(tokenBytes, secretBytes);
  return matches ? { ok: true } : { ok: false, reason: "unauthorized" };
}
