// The capped fallback Claude account: a team that has added no Claude account
// of its own can still run its first agent through one configured account,
// up to a fixed dollar amount of model usage, so a newcomer who has never
// heard of upstream accounts can just start (Leo, 2026-11-22: "how can
// someone who has no idea wtf is going on just start and keep going?").
//
// Off unless both env vars are set:
//   CODEROUTER_CLAUDE_FALLBACK_ACCOUNT_ID  the one account row it may use
//   CODEROUTER_CLAUDE_FALLBACK_CAP_USD     per-team cap, API-equivalent USD
// An id without a positive cap is refused: no cap, no fallback.
//
// This is the only path that reads a Claude account outside the caller's own
// team and access scope, and it reads exactly one row by the configured id.
// It applies only when the caller's team holds no Claude account row at all
// (counted without the caller's access filter, so a machine whose pool lacks
// the team's accounts still gets the team's own refusal, never the fallback).
//
// Spend is read from the ClickHouse ledger (`usage_events`, ordered by
// team_id, so the read touches only that team's rows) and cached per team in
// process for SPEND_TTL_MS; this process adds each fallback completion it
// records to the cached sum, so a burst inside one instance stops at the cap.
// Cost per request: one Map lookup; at most one ClickHouse read per team per
// SPEND_TTL_MS per instance. If the ledger cannot answer, the fallback is
// refused with a retryable error (fail closed).
import { eq } from "drizzle-orm";

import { cloudDb } from "../../db/client";
import { runWithCloudDbQuerySignal } from "../../db/queryScope";
import { coderouterClaudeAccounts } from "../../db/schema";
import { defaultClickHouseDependencies, query, type ClickHouseDependencies } from "./clickhouse";

export const FALLBACK_ACCOUNT_ENV = "CODEROUTER_CLAUDE_FALLBACK_ACCOUNT_ID";
export const FALLBACK_CAP_ENV = "CODEROUTER_CLAUDE_FALLBACK_CAP_USD";

const ACCOUNT_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const SPEND_TTL_MS = 60_000;
const MAX_CACHED_TEAMS = 10_000;
/**
 * Unpriced tokens (a model the rate card does not know) are charged at the
 * highest Claude rate on the card, $25 per million, so an unknown model can
 * never make fallback usage free.
 */
export const UNPRICED_USD_PER_TOKEN = 25 / 1_000_000;

export type ClaudeFallbackConfig =
  | { readonly kind: "off" }
  /** An id is set but the cap is missing, zero, or invalid. */
  | { readonly kind: "refused" }
  | { readonly kind: "on"; readonly accountId: string; readonly capUsd: number };

export function claudeFallbackConfig(env: Readonly<Record<string, string | undefined>> = process.env): ClaudeFallbackConfig {
  const id = env[FALLBACK_ACCOUNT_ENV]?.trim();
  if (!id) return { kind: "off" };
  if (!ACCOUNT_ID.test(id)) return { kind: "refused" };
  const rawCap = env[FALLBACK_CAP_ENV]?.trim();
  const capUsd = rawCap ? Number(rawCap) : 0;
  if (!Number.isFinite(capUsd) || capUsd <= 0) return { kind: "refused" };
  return { kind: "on", accountId: id.toLowerCase(), capUsd };
}

export type ClaudeFallbackSpend = {
  /** API-equivalent USD this team has used on the fallback account; `null` when the ledger cannot answer. */
  spentUsd(teamId: string, accountId: string, signal?: AbortSignal): Promise<number | null>;
  /** Adds a completion this process just recorded to the cached sum. */
  note(teamId: string, accountId: string, usd: number): void;
};

const SPEND_SQL = `SELECT
  sum(api_equivalent_usd) AS usd,
  sumIf(total_tokens, priced = 0) AS unpriced_tokens
FROM {db}.usage_events
WHERE team_id = {team_id:String}
  AND upstream_account_id = {account_id:String}`;

type SpendEntry = { usd: number; readAt: number };

export function createClaudeFallbackSpend(options: {
  readonly clickhouse?: ClickHouseDependencies;
  readonly now?: () => number;
  readonly ttlMs?: number;
  readonly read?: (teamId: string, accountId: string, signal?: AbortSignal) => Promise<number | null>;
} = {}): ClaudeFallbackSpend {
  const now = options.now ?? Date.now;
  const ttlMs = options.ttlMs ?? SPEND_TTL_MS;
  const clickhouse = options.clickhouse ?? defaultClickHouseDependencies;
  const cache = new Map<string, SpendEntry>();
  const inflight = new Map<string, Promise<number | null>>();
  const key = (teamId: string, accountId: string) => `${accountId}\x00${teamId}`;

  const read = options.read ?? (async (teamId: string, accountId: string, signal?: AbortSignal) => {
    const result = await query<{ usd?: unknown; unpriced_tokens?: unknown }>(
      SPEND_SQL,
      { team_id: teamId, account_id: accountId },
      clickhouse,
      { signal, timeoutMs: 3_000 },
    );
    if (!result.ok) return null;
    const row = result.rows[0] ?? {};
    const usd = Number(row.usd ?? 0);
    const unpriced = Number(row.unpriced_tokens ?? 0);
    if (!Number.isFinite(usd) || !Number.isFinite(unpriced)) return null;
    return usd + unpriced * UNPRICED_USD_PER_TOKEN;
  });

  async function spentUsd(teamId: string, accountId: string, signal?: AbortSignal): Promise<number | null> {
    const k = key(teamId, accountId);
    const cached = cache.get(k);
    if (cached && now() - cached.readAt < ttlMs) return cached.usd;
    let pending = inflight.get(k);
    if (!pending) {
      pending = read(teamId, accountId, signal).finally(() => inflight.delete(k));
      inflight.set(k, pending);
    }
    const usd = await pending;
    if (usd === null) return null;
    if (cache.size >= MAX_CACHED_TEAMS && !cache.has(k)) {
      const oldest = cache.keys().next().value;
      if (oldest !== undefined) cache.delete(oldest);
    }
    // A local completion noted while the read was in flight may be missing
    // from the ledger answer; keep the larger sum.
    const merged = Math.max(usd, cache.get(k)?.usd ?? 0);
    cache.delete(k);
    cache.set(k, { usd: merged, readAt: now() });
    return merged;
  }

  function note(teamId: string, accountId: string, usd: number): void {
    if (!Number.isFinite(usd) || usd <= 0) return;
    const entry = cache.get(key(teamId, accountId));
    if (entry) entry.usd += usd;
  }

  return { spentUsd, note };
}

/** The reads the fallback needs beyond the caller-scoped account store. */
export type ClaudeFallbackDependencies<Row> = {
  readonly config: () => ClaudeFallbackConfig;
  /** Whether the team holds any Claude account row, ignoring the caller's access scope. */
  readonly teamHasAnyAccount: (teamId: string, signal?: AbortSignal) => Promise<boolean>;
  /** The configured fallback row by id; the one read that crosses teams. */
  readonly loadAccount: (accountId: string, signal?: AbortSignal) => Promise<Row | null>;
  readonly spend: ClaudeFallbackSpend;
};

export const defaultClaudeFallbackSpend = createClaudeFallbackSpend();

export async function teamHasAnyClaudeAccount(teamId: string, signal?: AbortSignal): Promise<boolean> {
  const rows = await runWithCloudDbQuerySignal(signal, () => cloudDb()
    .select({ id: coderouterClaudeAccounts.id })
    .from(coderouterClaudeAccounts)
    .where(eq(coderouterClaudeAccounts.teamId, teamId))
    .limit(1));
  return rows.length > 0;
}

export async function loadClaudeAccountRowById(accountId: string, signal?: AbortSignal) {
  const [row] = await runWithCloudDbQuerySignal(signal, () => cloudDb()
    .select()
    .from(coderouterClaudeAccounts)
    .where(eq(coderouterClaudeAccounts.id, accountId))
    .limit(1));
  return row ?? null;
}
