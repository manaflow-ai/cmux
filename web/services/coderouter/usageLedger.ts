// First-party usage ledger: one `usage_events` row per model completion and
// one `route_events` row per routed request, written to ClickHouse from the
// same deferred path as the PostHog capture. Rows carry token counts, the
// rate-card estimate, and opaque identifiers only. No prompt, output, header,
// or credential is ever accepted here.
import { randomUUID } from "node:crypto";

import { deferCoderouterTask } from "./analytics";
import {
  CODEROUTER_API_RATE_CARD_VERSION,
  estimateApiEquivalent,
} from "./apiEquivalentPricing";
import {
  defaultClickHouseDependencies,
  insertRows,
  type ClickHouseInsertResult,
} from "./clickhouse";
import { reportCoderouterFailure } from "./observability";

export const USAGE_EVENTS_TABLE = "usage_events";
export const ROUTE_EVENTS_TABLE = "route_events";

export type UsageEventInput = {
  /** Shared with the route row of the same request. */
  readonly requestId: string;
  readonly teamId: string;
  readonly stackUserId: string;
  readonly vmId: string | null;
  readonly provider: string;
  /** Claude only; empty for every other provider. */
  readonly upstreamKind?: string;
  readonly agent: string;
  readonly model: string | undefined;
  readonly inputTokens: number;
  readonly cachedInputTokens: number;
  readonly outputTokens: number;
  readonly totalTokens: number;
  readonly status: number;
};

export type RouteEventInput = {
  readonly requestId: string;
  /** Absent before authentication succeeds. */
  readonly teamId?: string;
  readonly vmId?: string | null;
  readonly provider: string;
  readonly agent: string;
  readonly outcome: string;
  readonly failureStage: string;
  readonly status: number;
  readonly attemptCount: number;
  readonly refreshRetryCount: number;
  readonly durationMs: number;
  readonly responseStreamed: boolean;
};

/** Column-for-column shape of `usage_events`. */
export type UsageEventRow = {
  readonly event_time: string;
  readonly team_id: string;
  readonly stack_user_id: string;
  readonly vm_id: string | null;
  readonly provider: string;
  readonly upstream_kind: string;
  readonly agent: string;
  readonly model: string;
  readonly input_tokens: number;
  readonly cached_input_tokens: number;
  readonly output_tokens: number;
  readonly total_tokens: number;
  readonly api_equivalent_usd: number;
  readonly priced: 0 | 1;
  readonly rate_card_version: string;
  readonly request_id: string;
  readonly status: number;
};

/** Column-for-column shape of `route_events`. */
export type RouteEventRow = {
  readonly event_time: string;
  readonly team_id: string;
  readonly vm_id: string | null;
  readonly provider: string;
  readonly agent: string;
  readonly outcome: string;
  readonly failure_stage: string;
  readonly status: number;
  readonly attempt_count: number;
  readonly refresh_retry_count: number;
  readonly duration_ms: number;
  readonly response_streamed: 0 | 1;
  readonly request_id: string;
};

export type UsageLedgerDependencies = {
  readonly insert: (
    table: string,
    rows: readonly Readonly<Record<string, unknown>>[],
  ) => Promise<ClickHouseInsertResult>;
  readonly defer: (task: Promise<unknown>) => void;
  readonly now: () => Date;
};

const MAX_COUNT = 1_000_000_000_000;
const MAX_UINT8 = 255;
const MAX_UINT16 = 65_535;
const MAX_UINT32 = 4_294_967_295;
const ID_PATTERN = /^[A-Za-z0-9_-]{1,128}$/;

const defaultDependencies: UsageLedgerDependencies = {
  insert: (table, rows) => insertRows(table, rows, defaultClickHouseDependencies),
  defer: deferCoderouterTask,
  now: () => new Date(),
};

/** One id per proxied request, shared by its usage and route rows. */
export function newLedgerRequestId(): string {
  return randomUUID();
}

export function recordUsageEvent(
  input: UsageEventInput,
  dependencies: UsageLedgerDependencies = defaultDependencies,
): void {
  const row = usageEventRow(input, dependencies.now());
  if (!row) return;
  dependencies.defer(write(USAGE_EVENTS_TABLE, row, dependencies));
}

export function recordRouteEvent(
  input: RouteEventInput,
  dependencies: UsageLedgerDependencies = defaultDependencies,
): void {
  dependencies.defer(
    write(ROUTE_EVENTS_TABLE, routeEventRow(input, dependencies.now()), dependencies),
  );
}

/** Returns `null` for an empty completion, which is not billable usage. */
export function usageEventRow(
  input: UsageEventInput,
  now: Date,
): UsageEventRow | null {
  const inputTokens = safeCount(input.inputTokens);
  const cachedInputTokens = Math.min(inputTokens, safeCount(input.cachedInputTokens));
  const outputTokens = safeCount(input.outputTokens);
  const totalTokens = Math.max(inputTokens + outputTokens, safeCount(input.totalTokens));
  if (totalTokens === 0) return null;
  const model = boundedText(input.model, 128).toLowerCase() || "unknown";
  const estimate = estimateApiEquivalent({
    model,
    inputTokens,
    cachedInputTokens,
    outputTokens,
    totalTokens,
  });
  return {
    event_time: clickHouseDateTime(now),
    team_id: boundedText(input.teamId, 128),
    stack_user_id: boundedText(input.stackUserId, 128),
    vm_id: ledgerVmId(input.vmId),
    provider: boundedText(input.provider, 64) || "unknown",
    upstream_kind: boundedText(input.upstreamKind, 64),
    agent: boundedText(input.agent, 64) || "unknown",
    model,
    input_tokens: inputTokens,
    cached_input_tokens: cachedInputTokens,
    output_tokens: outputTokens,
    total_tokens: totalTokens,
    api_equivalent_usd: estimate.pricedTokens > 0 ? estimate.usd : 0,
    priced: estimate.pricedTokens > 0 ? 1 : 0,
    rate_card_version: CODEROUTER_API_RATE_CARD_VERSION,
    request_id: boundedText(input.requestId, 64),
    status: boundedInteger(input.status, MAX_UINT16),
  };
}

export function routeEventRow(input: RouteEventInput, now: Date): RouteEventRow {
  return {
    event_time: clickHouseDateTime(now),
    team_id: boundedText(input.teamId, 128),
    vm_id: ledgerVmId(input.vmId ?? null),
    provider: boundedText(input.provider, 64) || "unknown",
    agent: boundedText(input.agent, 64) || "unknown",
    outcome: boundedText(input.outcome, 64) || "unknown",
    failure_stage: boundedText(input.failureStage, 64) || "unknown",
    status: boundedInteger(input.status, MAX_UINT16),
    attempt_count: boundedInteger(input.attemptCount, MAX_UINT8),
    refresh_retry_count: boundedInteger(input.refreshRetryCount, MAX_UINT8),
    duration_ms: boundedInteger(Math.round(input.durationMs), MAX_UINT32),
    response_streamed: input.responseStreamed ? 1 : 0,
    request_id: boundedText(input.requestId, 64),
  };
}

async function write(
  table: string,
  row: UsageEventRow | RouteEventRow,
  dependencies: UsageLedgerDependencies,
): Promise<void> {
  let result: ClickHouseInsertResult;
  try {
    result = await dependencies.insert(table, [row]);
  } catch {
    result = { ok: false, reason: "request_failed" };
  }
  // A disabled ledger already reported itself once from the client.
  if (result.ok || result.reason === "disabled") return;
  reportCoderouterFailure(
    "usage_ledger",
    new Error("CodeRouter usage ledger insert failed"),
    {
      table,
      reason: result.reason,
      ...(result.reason === "status" ? { status: result.status } : {}),
    },
  );
}

/** `YYYY-MM-DD HH:MM:SS.mmm` in UTC, the DateTime64(3) input form. */
export function clickHouseDateTime(date: Date): string {
  return date.toISOString().replace("T", " ").replace("Z", "");
}

function ledgerVmId(value: string | null | undefined): string | null {
  return typeof value === "string" && ID_PATTERN.test(value) ? value : null;
}

function boundedText(value: string | undefined, max: number): string {
  return typeof value === "string" ? value.trim().slice(0, max) : "";
}

function safeCount(value: number): number {
  return Number.isSafeInteger(value) && value >= 0 && value <= MAX_COUNT
    ? value
    : 0;
}

function boundedInteger(value: number, max: number): number {
  return Number.isInteger(value) && value >= 0 && value <= max ? value : 0;
}
