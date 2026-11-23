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
import { and, eq } from "drizzle-orm";

import { cloudDb } from "../../db/client";
import { runWithCloudDbQuerySignal } from "../../db/queryScope";
import { cloudVms, coderouterClaudeAccounts } from "../../db/schema";
import { defaultClickHouseDependencies, query, type ClickHouseDependencies } from "./clickhouse";

export const FALLBACK_ACCOUNT_ENV = "CODEROUTER_CLAUDE_FALLBACK_ACCOUNT_ID";

const ACCOUNT_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const SPEND_TTL_MS = 60_000;
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
  /** The caller's plan id, or null when the router cannot tell (refused). */
  readonly planId: (caller: FallbackCaller, signal?: AbortSignal) => Promise<string | null>;
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
  const planId = await dependencies.planId(caller, signal);
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
 * The plan of the Cloud machine making the request, from `cloud_vms` (a
 * primary-key read). A caller that is not a machine of its team has no plan
 * here, so the house route refuses it.
 */
export async function fallbackPlanIdForCaller(caller: FallbackCaller, signal?: AbortSignal): Promise<string | null> {
  if (!caller.vmId || !ACCOUNT_ID.test(caller.vmId)) return null;
  const [row] = await runWithCloudDbQuerySignal(signal, () => cloudDb()
    .select({ planId: cloudVms.billingPlanId })
    .from(cloudVms)
    .where(and(eq(cloudVms.id, caller.vmId!), eq(cloudVms.ownerTeamId, caller.teamId)))
    .limit(1));
  return row?.planId ?? null;
}

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
