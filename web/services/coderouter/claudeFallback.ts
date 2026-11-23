// The house Claude route: a team that has attached no Claude account of its
// own can still run its first agent through one configured account, up to the
// model usage its plan includes, so a newcomer who has never heard of
// upstream accounts can just start (Leo, 2026-11-22: "how can someone who has
// no idea wtf is going on just start and keep going?").
//
// Off unless CODEROUTER_CLAUDE_FALLBACK_ACCOUNT_ID names the one account row
// it may use. With it unset nothing here runs and every answer is today's.
//
// This is the only path that reads a Claude account outside the caller's own
// team and access scope, and it reads exactly one row by the configured id.
// It applies only while the caller's team holds no Claude account row at all
// (counted without the caller's access filter, so a machine whose pool lacks
// the team's accounts still gets the team's own refusal, never this route),
// and it is never mixed with the team's own accounts.
//
// The cap (pricing lane, hq#19720, RFD 0052): cents at list price, by plan,
// one-time and never refilled; the taste plan also shares one global daily
// budget. Only Sonnet-tier models and below. Spend is the router's own ledger
// (ClickHouse `usage_events`, `api_equivalent_usd`, the rate card's list
// price), read BEFORE forwarding; a read that fails refuses (fail closed).
//
// Cost per request: one Map lookup per sum while cached; at most one
// ClickHouse read per team (and one global read) per SPEND_TTL_MS per
// instance. The team read touches only that team's rows (`usage_events` is
// ordered by team_id); the global read touches one day's partition slice.
// Each fallback completion this process records is added to both cached sums
// so a burst inside one instance stops at the cap.
//
// The plan (cmux#51317, services/billing/cloudIntro.ts there): the $1 pass and
// the free week are written on the buyer's Stack sign-in record as
// `cmuxNextPlan` with `cmuxNextPlanEndsAt`, never into `cloud_vms`'
// `billing_plan_id` (that column mirrors only `cmuxVmPlan`/`cmuxPlan`, and
// classic VM code branches on it). The router reads the calling machine's
// creator (`cloud_vms.user_id`, a primary-key read) and then that user's
// record, like resolveProPlanStatus. A missing plan or end, an unreadable end,
// or an end that has passed is no plan (cap 0, today's answer); a read that
// fails refuses (fail closed). The answer is cached per team and machine for
// PLAN_TTL_MS, and never past the pass's own end, so a request costs one Map
// lookup while cached and at most one Postgres read plus one Stack read per
// machine per PLAN_TTL_MS per instance.
import { and, eq } from "drizzle-orm";

import { cloudDb } from "../../db/client";
import { runWithCloudDbQuerySignal } from "../../db/queryScope";
import { cloudVms, coderouterClaudeAccounts } from "../../db/schema";
import { getStackServerApp } from "../../app/lib/stack";
import { withStackDeadline } from "../teams/stack";
import { defaultClickHouseDependencies, query, type ClickHouseDependencies } from "./clickhouse";

export const FALLBACK_ACCOUNT_ENV = "CODEROUTER_CLAUDE_FALLBACK_ACCOUNT_ID";

const ACCOUNT_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const SPEND_TTL_MS = 60_000;
const PLAN_TTL_MS = 60_000;
const MAX_CACHED_TEAMS = 10_000;

/** Included usage per plan, in cents at list price; one-time, not refilled. */
export const FALLBACK_PLAN_CAP_CENTS: Readonly<Record<string, number>> = {
  next_intro: 500,
  next_taste: 50,
};
/** Plans whose usage also draws on the one global daily budget. */
export const GLOBAL_BUDGET_PLANS: ReadonlySet<string> = new Set(["next_taste"]);
/** The taste plans' shared budget: 100 dollars a day (UTC) at list price. */
export const GLOBAL_DAILY_BUDGET_CENTS = 10_000;
/** The share of a team's cap at which each answer carries a one-line notice. */
export const NOTICE_AT_FRACTION = 0.8;
/**
 * Unpriced tokens (a model the rate card does not know) are charged at the
 * highest Claude rate on the card, $25 per million, so an unknown model can
 * never make included usage free.
 */
export const UNPRICED_USD_PER_TOKEN = 25 / 1_000_000;

/** A plan's included usage; 0 (refused, as today) for every other plan. */
export function fallbackCapCents(planId: string | null | undefined): number {
  if (!planId) return 0;
  return FALLBACK_PLAN_CAP_CENTS[planId.trim().toLowerCase()] ?? 0;
}

/**
 * The sign-in record keys the pass writes (cmux#51317's
 * CLOUD_INTRO_METADATA_KEYS); read here, never written.
 */
export const NEXT_PLAN_METADATA_KEYS = { plan: "cmuxNextPlan", endsAt: "cmuxNextPlanEndsAt" } as const;

export type NextPlan = { readonly planId: string | null; readonly endsAtMs: number | null };

/**
 * The plan a sign-in record holds now: only while its end is readable and
 * still ahead. Anything else (no plan, no end, an unparseable end, an end
 * that has passed) is no plan, which the cap turns into today's refusal.
 */
export function nextPlanFromMetadata(metadata: unknown, nowMs: number): NextPlan {
  const none = { planId: null, endsAtMs: null };
  if (!metadata || typeof metadata !== "object" || Array.isArray(metadata)) return none;
  const record = metadata as Record<string, unknown>;
  const plan = record[NEXT_PLAN_METADATA_KEYS.plan];
  const endsAt = record[NEXT_PLAN_METADATA_KEYS.endsAt];
  if (typeof plan !== "string" || !plan.trim() || typeof endsAt !== "string") return none;
  const endsAtMs = new Date(endsAt).getTime();
  if (!Number.isFinite(endsAtMs) || endsAtMs <= nowMs) return none;
  return { planId: plan.trim().toLowerCase(), endsAtMs };
}

/** The caller's plan, or `unavailable` when a read failed (refused, fail closed). */
export type FallbackPlanRead =
  | { readonly kind: "plan"; readonly planId: string | null }
  | { readonly kind: "unavailable" };

type PlanEntry = NextPlan & { readonly readAt: number };

/**
 * The cached plan read. `readVmUser` answers the machine's creator on its
 * team (null when it is not that team's machine); `readUserMetadata` answers
 * the user's `clientReadOnlyMetadata` (null when the user is gone). Either
 * throwing is a failed read: refused and not cached.
 */
export function createFallbackPlanReader(options: {
  readonly readVmUser?: (caller: { readonly teamId: string; readonly vmId: string }, signal?: AbortSignal) => Promise<string | null>;
  readonly readUserMetadata?: (userId: string) => Promise<unknown>;
  readonly now?: () => number;
  readonly ttlMs?: number;
} = {}): (caller: FallbackCaller, signal?: AbortSignal) => Promise<FallbackPlanRead> {
  const now = options.now ?? Date.now;
  const ttlMs = options.ttlMs ?? PLAN_TTL_MS;
  const readVmUser = options.readVmUser ?? readFallbackVmUser;
  const readUserMetadata = options.readUserMetadata ?? readStackUserMetadata;
  const cache = new Map<string, PlanEntry>();
  const inflight = new Map<string, Promise<NextPlan | null>>();

  const read = async (teamId: string, vmId: string, signal?: AbortSignal): Promise<NextPlan | null> => {
    try {
      const userId = await readVmUser({ teamId, vmId }, signal);
      if (!userId) return { planId: null, endsAtMs: null };
      return nextPlanFromMetadata(await readUserMetadata(userId), now());
    } catch {
      return null;
    }
  };

  return async (caller, signal) => {
    if (!caller.vmId || !ACCOUNT_ID.test(caller.vmId)) return { kind: "plan", planId: null };
    const key = `${caller.teamId}\x00${caller.vmId}`;
    const at = now();
    const entry = cache.get(key);
    if (entry && at - entry.readAt < ttlMs) {
      // A pass that ended inside the window ends here too.
      return { kind: "plan", planId: entry.endsAtMs !== null && at >= entry.endsAtMs ? null : entry.planId };
    }
    let pending = inflight.get(key);
    if (!pending) {
      pending = read(caller.teamId, caller.vmId, signal).finally(() => inflight.delete(key));
      inflight.set(key, pending);
    }
    const plan = await pending;
    if (!plan) return { kind: "unavailable" };
    cache.delete(key);
    if (cache.size >= MAX_CACHED_TEAMS) {
      const oldest = cache.keys().next().value;
      if (oldest !== undefined) cache.delete(oldest);
    }
    cache.set(key, { ...plan, readAt: now() });
    return { kind: "plan", planId: plan.planId };
  };
}

/**
 * Sonnet tier and below. Anything else, including an unknown or missing
 * model, is refused with the sign-in step; nothing is silently downgraded.
 */
export function fallbackModelAllowed(model: string | null): boolean {
  if (!model) return false;
  const normalized = model.trim().toLowerCase();
  return /^claude-(?:sonnet|haiku)-[a-z0-9.-]+$/.test(normalized) ||
    /^claude-3(?:[.-][57])?-(?:sonnet|haiku)-[a-z0-9.-]+$/.test(normalized);
}

export type ClaudeFallbackConfig =
  | { readonly kind: "off" }
  | { readonly kind: "on"; readonly accountId: string };

/** An unset or malformed id is off: nothing can reach another team's account. */
export function claudeFallbackConfig(env: Readonly<Record<string, string | undefined>> = process.env): ClaudeFallbackConfig {
  const id = env[FALLBACK_ACCOUNT_ENV]?.trim();
  if (!id || !ACCOUNT_ID.test(id)) return { kind: "off" };
  return { kind: "on", accountId: id.toLowerCase() };
}

export type FallbackRefusal = "included_usage_used_up" | "model_not_included" | "included_daily_budget_reached";

export type ClaudeFallbackSpend = {
  /** List-price cents this team has used on the account; `null` when the ledger cannot answer. */
  teamCents(teamId: string, accountId: string, signal?: AbortSignal): Promise<number | null>;
  /** List-price cents every team has used on the account today (UTC); `null` when the ledger cannot answer. */
  todayCents(accountId: string, signal?: AbortSignal): Promise<number | null>;
  /** Adds a completion this process just recorded to the cached sums. */
  note(teamId: string, accountId: string, cents: number): void;
};

const SUMS_SQL = `
  sum(api_equivalent_usd) AS usd,
  sumIf(total_tokens, priced = 0) AS unpriced_tokens
FROM {db}.usage_events`;
const TEAM_SPEND_SQL = `SELECT${SUMS_SQL}
WHERE team_id = {team_id:String}
  AND upstream_account_id = {account_id:String}`;
const TODAY_SPEND_SQL = `SELECT${SUMS_SQL}
WHERE event_time >= toStartOfDay(now('UTC'))
  AND upstream_account_id = {account_id:String}`;

type SpendEntry = { cents: number; readAt: number; day?: string };

export function createClaudeFallbackSpend(options: {
  readonly clickhouse?: ClickHouseDependencies;
  readonly now?: () => number;
  readonly ttlMs?: number;
  readonly readTeam?: (teamId: string, accountId: string, signal?: AbortSignal) => Promise<number | null>;
  readonly readToday?: (accountId: string, signal?: AbortSignal) => Promise<number | null>;
} = {}): ClaudeFallbackSpend {
  const now = options.now ?? Date.now;
  const ttlMs = options.ttlMs ?? SPEND_TTL_MS;
  const clickhouse = options.clickhouse ?? defaultClickHouseDependencies;
  const teams = new Map<string, SpendEntry>();
  const today = new Map<string, SpendEntry>();
  const inflight = new Map<string, Promise<number | null>>();

  const sum = async (sql: string, params: Record<string, string>, signal?: AbortSignal) => {
    const result = await query<{ usd?: unknown; unpriced_tokens?: unknown }>(sql, params, clickhouse, { signal, timeoutMs: 3_000 });
    if (!result.ok) return null;
    const row = result.rows[0] ?? {};
    const usd = Number(row.usd ?? 0);
    const unpriced = Number(row.unpriced_tokens ?? 0);
    if (!Number.isFinite(usd) || !Number.isFinite(unpriced)) return null;
    return (usd + unpriced * UNPRICED_USD_PER_TOKEN) * 100;
  };
  const readTeam = options.readTeam ??
    ((teamId: string, accountId: string, signal?: AbortSignal) => sum(TEAM_SPEND_SQL, { team_id: teamId, account_id: accountId }, signal));
  const readToday = options.readToday ??
    ((accountId: string, signal?: AbortSignal) => sum(TODAY_SPEND_SQL, { account_id: accountId }, signal));
  const utcDay = () => new Date(now()).toISOString().slice(0, 10);

  async function cached(
    cache: Map<string, SpendEntry>,
    key: string,
    read: () => Promise<number | null>,
    day?: string,
  ): Promise<number | null> {
    const entry = cache.get(key);
    if (entry && entry.day === day && now() - entry.readAt < ttlMs) return entry.cents;
    const flightKey = `${cache === teams ? "t" : "d"}\x00${key}`;
    let pending = inflight.get(flightKey);
    if (!pending) {
      pending = read().finally(() => inflight.delete(flightKey));
      inflight.set(flightKey, pending);
    }
    const cents = await pending;
    if (cents === null) return null;
    // Spend only grows: a completion noted while the read was in flight may be
    // missing from the ledger's answer, so keep the larger (same day only).
    const prior = cache.get(key);
    const merged = prior && prior.day === day ? Math.max(cents, prior.cents) : cents;
    cache.delete(key);
    if (cache.size >= MAX_CACHED_TEAMS) {
      const oldest = cache.keys().next().value;
      if (oldest !== undefined) cache.delete(oldest);
    }
    cache.set(key, { cents: merged, readAt: now(), ...(day ? { day } : {}) });
    return merged;
  }

  return {
    teamCents: (teamId, accountId, signal) =>
      cached(teams, `${accountId}\x00${teamId}`, () => readTeam(teamId, accountId, signal)),
    todayCents: (accountId, signal) => cached(today, accountId, () => readToday(accountId, signal), utcDay()),
    note(teamId, accountId, cents) {
      if (!Number.isFinite(cents) || cents <= 0) return;
      const team = teams.get(`${accountId}\x00${teamId}`);
      if (team) team.cents += cents;
      const day = today.get(accountId);
      if (day && day.day === utcDay()) day.cents += cents;
    },
  };
}

/** The reads the house route needs beyond the caller-scoped account store. */
export type ClaudeFallbackDependencies<Row> = {
  readonly config: () => ClaudeFallbackConfig;
  /** Whether the team holds any Claude account row, ignoring the caller's access scope. */
  readonly teamHasAnyAccount: (teamId: string, signal?: AbortSignal) => Promise<boolean>;
  /** The caller's plan now; a plan of null is today's answer, `unavailable` refuses (fail closed). */
  readonly planId: (caller: FallbackCaller, signal?: AbortSignal) => Promise<FallbackPlanRead>;
  /** The configured row by id; the one read that crosses teams. */
  readonly loadAccount: (accountId: string, signal?: AbortSignal) => Promise<Row | null>;
  readonly spend: ClaudeFallbackSpend;
};

export type FallbackCaller = { readonly teamId: string; readonly vmId: string | null };

export type FallbackDecision<Row> =
  | { readonly kind: "none" }
  | { readonly kind: "refused"; readonly reason: FallbackRefusal }
  | { readonly kind: "unavailable" }
  | {
    readonly kind: "row";
    readonly row: Row;
    readonly spentCents: number;
    readonly capCents: number;
  };

/**
 * Whether the house route serves this caller, decided before anything is
 * forwarded. `model` reads the requested model (`null` when unreadable); it
 * is absent for a request that names none (the model list).
 * Only called once the caller's own account list came back empty.
 */
export async function decideClaudeFallback<Row extends { readonly id: string }>(
  dependencies: ClaudeFallbackDependencies<Row> | undefined,
  caller: FallbackCaller,
  model: (() => string | null) | undefined,
  signal?: AbortSignal,
): Promise<FallbackDecision<Row>> {
  if (!dependencies) return { kind: "none" };
  const config = dependencies.config();
  if (config.kind !== "on") return { kind: "none" };
  // Rows the caller cannot see still belong to its team: that team uses its
  // own accounts (or is told to share one), never the house route.
  if (await dependencies.teamHasAnyAccount(caller.teamId, signal)) return { kind: "none" };
  const plan = await dependencies.planId(caller, signal);
  if (plan.kind === "unavailable") return { kind: "unavailable" };
  const planId = plan.planId;
  const capCents = fallbackCapCents(planId);
  if (capCents <= 0) return { kind: "none" };
  if (model && !fallbackModelAllowed(model())) return { kind: "refused", reason: "model_not_included" };
  const spentCents = await dependencies.spend.teamCents(caller.teamId, config.accountId, signal);
  if (spentCents === null) return { kind: "unavailable" };
  if (spentCents >= capCents) return { kind: "refused", reason: "included_usage_used_up" };
  if (planId && GLOBAL_BUDGET_PLANS.has(planId.trim().toLowerCase())) {
    const todayCents = await dependencies.spend.todayCents(config.accountId, signal);
    if (todayCents === null) return { kind: "unavailable" };
    if (todayCents >= GLOBAL_DAILY_BUDGET_CENTS) return { kind: "refused", reason: "included_daily_budget_reached" };
  }
  const row = await dependencies.loadAccount(config.accountId, signal);
  if (!row || row.id.toLowerCase() !== config.accountId) return { kind: "none" };
  return { kind: "row", row, spentCents, capCents };
}

export const defaultClaudeFallbackSpend = createClaudeFallbackSpend();

export async function teamHasAnyClaudeAccount(teamId: string, signal?: AbortSignal): Promise<boolean> {
  const rows = await runWithCloudDbQuerySignal(signal, () => cloudDb()
    .select({ id: coderouterClaudeAccounts.id })
    .from(coderouterClaudeAccounts)
    .where(eq(coderouterClaudeAccounts.teamId, teamId))
    .limit(1));
  return rows.length > 0;
}

/**
 * The creator of the Cloud machine making the request, from `cloud_vms` (a
 * primary-key read). A caller that is not a machine of its team has no user
 * here, so it has no plan and the house route refuses it.
 */
async function readFallbackVmUser(caller: { readonly teamId: string; readonly vmId: string }, signal?: AbortSignal): Promise<string | null> {
  const [row] = await runWithCloudDbQuerySignal(signal, () => cloudDb()
    .select({ userId: cloudVms.userId })
    .from(cloudVms)
    .where(and(eq(cloudVms.id, caller.vmId), eq(cloudVms.ownerTeamId, caller.teamId)))
    .limit(1));
  return row?.userId || null;
}

/** The user's sign-in record metadata, under the Stack deadline; null when the user is gone. */
async function readStackUserMetadata(userId: string): Promise<unknown> {
  const user = await withStackDeadline(() => getStackServerApp().getUser(userId));
  return user?.clientReadOnlyMetadata ?? null;
}

export const fallbackPlanForCaller = createFallbackPlanReader();

export async function loadClaudeAccountRowById(accountId: string, signal?: AbortSignal) {
  const [row] = await runWithCloudDbQuerySignal(signal, () => cloudDb()
    .select()
    .from(coderouterClaudeAccounts)
    .where(eq(coderouterClaudeAccounts.id, accountId))
    .limit(1));
  return row ?? null;
}

/** The one-line notice once a team has used NOTICE_AT_FRACTION of its included usage. */
export const INCLUDED_USAGE_NOTICE = "You have used most of the model usage included with your pass.";
export const INCLUDED_USAGE_NOTICE_HEADER = "x-cmux-included-usage-notice";
export const FALLBACK_REFUSAL_HEADER = "x-cmux-refusal-reason";

export function includedUsageNotice(included: { readonly spentCents: number; readonly capCents: number } | undefined): string | null {
  if (!included || included.capCents <= 0) return null;
  return included.spentCents >= included.capCents * NOTICE_AT_FRACTION ? INCLUDED_USAGE_NOTICE : null;
}

/** The requested model of an Anthropic Messages body, or null when unreadable. */
export function requestedModel(bytes: Uint8Array | null): string | null {
  if (!bytes || bytes.byteLength === 0) return null;
  try {
    const parsed: unknown = JSON.parse(new TextDecoder().decode(bytes));
    const model = parsed && typeof parsed === "object" ? (parsed as { model?: unknown }).model : undefined;
    return typeof model === "string" ? model : null;
  } catch {
    return null;
  }
}
