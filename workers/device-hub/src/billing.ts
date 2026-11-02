import type { Env } from "./env";

/**
 * Whether the user may use the cmux relay, decided by cmux billing, not by
 * the hub. The hub asks the cmux web backend of the user's Stack project
 * (`GET /api/billing/plan`, the endpoint the apps use for the plan) with the
 * user's own Stack access token, so it holds no billing secret and copies no
 * billing rules: the web backend resolves Stripe and App Store subscriptions,
 * operator and staff grants, and the billing team.
 *
 * `paid`: the personal plan is Pro or Max, or the billing team is on Team.
 * `free`: anything else (Free, Go). `error`: no answer we can trust (no
 * backend for the project, timeout, network failure, non-200, a body that is
 * not about this user). Callers treat `error` as `free`: no cmux relay.
 */
export type RelayEntitlement = "paid" | "free" | "error";

const DEFAULT_TIMEOUT_MS = 5000;
/** Personal plans that include the cmux relay (`subscriptionPlanId`). */
const RELAY_PERSONAL_PLANS = new Set(["pro", "max"]);
/** Team plans that include it (`teamPlanId`). */
const RELAY_TEAM_PLANS = new Set(["team"]);

/** `BILLING_ORIGINS`: comma list of `<stackProjectId>=<cmux web origin>`. */
export function billingOrigin(env: Pick<Env, "BILLING_ORIGINS">, projectId: string): string | null {
  for (const pair of (env.BILLING_ORIGINS ?? "").split(",")) {
    const eq = pair.indexOf("=");
    if (eq <= 0) continue;
    if (pair.slice(0, eq).trim() !== projectId) continue;
    const origin = pair.slice(eq + 1).trim().replace(/\/+$/, "");
    try {
      // Exactly an https origin: no path, query, fragment or credentials.
      const u = new URL(origin);
      return u.protocol === "https:" && u.origin === origin ? origin : null;
    } catch {
      return null;
    }
  }
  return null;
}

function timeoutMs(env: Pick<Env, "BILLING_TIMEOUT_MS">): number {
  const v = Number(env.BILLING_TIMEOUT_MS);
  return Number.isFinite(v) && v > 0 ? v : DEFAULT_TIMEOUT_MS;
}

/** Splits a hub user id `<projectId>:<stackUserId>`. */
function splitUserId(userId: string): { projectId: string; sub: string } | null {
  const i = userId.indexOf(":");
  if (i <= 0 || i === userId.length - 1) return null;
  return { projectId: userId.slice(0, i), sub: userId.slice(i + 1) };
}

/** Reads the plan answer. Anything that is not clearly this user's plan is `error`. */
function decide(body: unknown, sub: string): RelayEntitlement {
  if (!body || typeof body !== "object") return "error";
  const b = body as Record<string, unknown>;
  if (b.authenticated !== true) return "error";
  const user = b.user as Record<string, unknown> | null | undefined;
  if (!user || user.id !== sub) return "error";
  const personal = typeof b.subscriptionPlanId === "string" ? b.subscriptionPlanId : null;
  const team = typeof b.teamPlanId === "string" ? b.teamPlanId : null;
  if (personal && RELAY_PERSONAL_PLANS.has(personal)) return "paid";
  if (team && RELAY_TEAM_PLANS.has(team)) return "paid";
  return "free";
}

/**
 * Asks cmux billing whether `userId` may use the cmux relay now. No cache:
 * every ticket and every `/ice` refresh asks again, so a lapsed subscription
 * stops getting the relay on its next request. Logs only the outcome.
 */
export async function relayEntitlement(env: Env, userId: string, stackToken: string | null): Promise<RelayEntitlement> {
  const outcome = await lookup(env, userId, stackToken);
  console.log(`relay entitlement: ${outcome.result}${outcome.reason ? ` (${outcome.reason})` : ""}`);
  return outcome.result;
}

async function lookup(env: Env, userId: string, stackToken: string | null): Promise<{ result: RelayEntitlement; reason?: string }> {
  const who = splitUserId(userId);
  if (!who) return { result: "error", reason: "bad user id" };
  if (!stackToken) return { result: "error", reason: "no stack token" };
  const origin = billingOrigin(env, who.projectId);
  if (!origin) return { result: "error", reason: "no billing origin for project" };
  let res: Response;
  try {
    res = await fetch(`${origin}/api/billing/plan`, {
      method: "GET",
      // Stack's server SDK reads the caller's session from `x-stack-auth`; the
      // backend verifies the token with Stack before it answers.
      headers: { accept: "application/json", "x-stack-auth": JSON.stringify({ accessToken: stackToken }) },
      // Workers reject `redirect: "error"`; a redirect stays a non-200 here and fails closed.
      redirect: "manual",
      signal: AbortSignal.timeout(timeoutMs(env)),
    });
  } catch (err) {
    const name = err instanceof Error ? err.name : "";
    return { result: "error", reason: name === "TimeoutError" || name === "AbortError" ? "timeout" : "network" };
  }
  if (res.status !== 200) {
    await res.body?.cancel();
    return { result: "error", reason: `status ${res.status}` };
  }
  let body: unknown;
  try {
    body = await res.json();
  } catch {
    return { result: "error", reason: "bad body" };
  }
  const result = decide(body, who.sub);
  return result === "error" ? { result, reason: "not this user's plan" } : { result };
}
