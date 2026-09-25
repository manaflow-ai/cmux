// Customer-facing usage totals for long-lived CodeRouter API keys. The ledger
// stores only opaque key ids, token counts, and rate-card estimates, so this
// module can report useful usage without exposing prompts, outputs, models, or
// member identities.
import {
  defaultClickHouseDependencies,
  query,
  type ClickHouseDependencies,
} from "./clickhouse";
import {
  DAY_WINDOW_SQL,
  dayWindowParams,
  parseTotals,
  queryFailure,
  rowRecord,
  USAGE_COLUMNS,
  USAGE_SUMS_SQL,
  type UsageTotals,
} from "./ledgerMetrics";
import { reportCoderouterFailure } from "./observability";

const API_KEY_USAGE_COLUMNS = ["api_key_id", "completions", ...USAGE_COLUMNS] as const;
const MAX_KEY_IDS_PER_QUERY = 500;

function apiKeyUsageSql(keyCount: number): string {
  const keyPlaceholders = Array.from({ length: keyCount }, (_, index) => `{key_id_${index}:String}`).join(", ");
  return `SELECT
  api_key_id,
  count() AS completions,${USAGE_SUMS_SQL}
FROM {db}.usage_events
WHERE team_id = {team_id:String}
  AND api_key_id IS NOT NULL
  AND api_key_id IN (${keyPlaceholders})
  AND ${DAY_WINDOW_SQL}
GROUP BY api_key_id`;
}

export type CoderouterApiKeyUsage = UsageTotals & {
  readonly completions: number;
};

export type CoderouterApiKeyUsageResult =
  | { readonly kind: "ready"; readonly byKey: Readonly<Record<string, CoderouterApiKeyUsage>> }
  | { readonly kind: "unavailable" };

type ApiKeyMetricsDependencies = {
  readonly clickhouse: ClickHouseDependencies;
  readonly now: () => Date;
  readonly reportFailure?: (reason: string, status?: number) => void;
};

const defaultDependencies: ApiKeyMetricsDependencies = {
  clickhouse: defaultClickHouseDependencies,
  now: () => new Date(),
  reportFailure: (reason, status) => {
    reportCoderouterFailure(
      "analytics_query",
      new Error("CodeRouter API-key usage query failed"),
      {
        reason,
        ...(status === undefined ? {} : { status }),
      },
    );
  },
};

export async function loadCoderouterApiKeyUsage(
  authorizedTeamId: string,
  keyIds: readonly string[],
  dependencies: ApiKeyMetricsDependencies = defaultDependencies,
): Promise<CoderouterApiKeyUsageResult> {
  if (keyIds.length === 0) return { kind: "ready", byKey: {} };
  if (keyIds.length > MAX_KEY_IDS_PER_QUERY) return { kind: "unavailable" };
  const keyIdParams = Object.fromEntries(keyIds.map((keyId, index) => [`key_id_${index}`, keyId]));
  const result = await query<unknown>(
    apiKeyUsageSql(keyIds.length),
    { team_id: authorizedTeamId, ...dayWindowParams(dependencies.now()), ...keyIdParams },
    dependencies.clickhouse,
  );
  if (!result.ok) {
    const failure = queryFailure(result);
    dependencies.reportFailure?.(failure.reason, failure.status);
    return { kind: "unavailable" };
  }

  const allowedKeyIds = new Set(keyIds);
  const byKey: Record<string, CoderouterApiKeyUsage> = {};
  for (const row of result.rows) {
    const record = rowRecord(row, API_KEY_USAGE_COLUMNS);
    if (!record) {
      dependencies.reportFailure?.("malformed_response");
      return { kind: "unavailable" };
    }
    const keyId = record.api_key_id;
    const completions = nonNegativeInteger(record.completions);
    const totals = parseTotals(record);
    if (typeof keyId !== "string" || completions === null || !totals) {
      dependencies.reportFailure?.("invalid_metrics");
      return { kind: "unavailable" };
    }
    // A revoked or deleted key can leave historical ledger rows behind. The
    // control-plane list remains authoritative for which rows are returned.
    if (!allowedKeyIds.has(keyId)) continue;
    byKey[keyId] = { completions, ...totals };
  }
  return { kind: "ready", byKey };
}

function nonNegativeInteger(value: unknown): number | null {
  const number = typeof value === "number"
    ? value
    : typeof value === "string" && value.trim()
    ? Number(value)
    : Number.NaN;
  return Number.isSafeInteger(number) && number >= 0 ? number : null;
}

const __test = {
  apiKeyUsageSql,
};
