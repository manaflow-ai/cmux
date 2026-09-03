// Coderouter dependency health, for `GET /api/coderouter/health` (uptime
// monitors) and the alert cron. Each check is bounded and reports a status,
// never a value: no connection string, key id, or host name leaves the
// process. `degraded` means the data plane still routes but usage or
// analytics are dark; `down` means requests would fail.
import { sql } from "drizzle-orm";

import { cloudDb } from "../../db/client";
import { clickHouseConfig, query as clickHouseQuery } from "./clickhouse";

export type HealthStatus = "ok" | "degraded" | "down";

export type HealthCheck = {
  readonly name: "postgres" | "clickhouse" | "analytics_config" | "kms_config";
  readonly ok: boolean;
  /** Whether a failure takes the data plane down or only darkens telemetry. */
  readonly critical: boolean;
  readonly latencyMs?: number;
  /** A short, secret-free reason when `ok` is false. */
  readonly reason?: string;
};

export type CoderouterHealth = {
  readonly status: HealthStatus;
  readonly checks: readonly HealthCheck[];
  readonly checkedAt: string;
};

export type HealthDependencies = {
  readonly pingPostgres: () => Promise<void>;
  readonly pingClickHouse: () => Promise<{ ok: true } | { ok: false; reason: string }>;
  readonly env: Record<string, string | undefined>;
  readonly timeoutMs: number;
};

export const HEALTH_CHECK_TIMEOUT_MS = 4_000;

export const defaultHealthDependencies: HealthDependencies = {
  pingPostgres: async () => {
    await cloudDb().execute(sql`select 1`);
  },
  pingClickHouse: async () => {
    if (!clickHouseConfig()) return { ok: false, reason: "not_configured" };
    const result = await clickHouseQuery<{ one: number }>("SELECT 1 AS one", {});
    if (result.ok) return { ok: true };
    return { ok: false, reason: result.reason === "status" ? `http_${result.status}` : result.reason };
  },
  env: process.env,
  timeoutMs: HEALTH_CHECK_TIMEOUT_MS,
};

export async function coderouterHealth(
  dependencies: HealthDependencies = defaultHealthDependencies,
): Promise<CoderouterHealth> {
  const [postgres, clickhouse] = await Promise.all([
    timed("postgres", true, dependencies.timeoutMs, async () => {
      await dependencies.pingPostgres();
      return { ok: true as const };
    }),
    timed("clickhouse", false, dependencies.timeoutMs, dependencies.pingClickHouse),
  ]);
  const env = dependencies.env;
  const analyticsConfigured =
    Boolean(env.POSTHOG_CODEROUTER_PROJECT_KEY?.trim()) &&
    (env.CODEROUTER_ANALYTICS_SCOPE_SECRET?.trim().length ?? 0) >= 32;
  const kmsConfigured = Boolean(env.CODEROUTER_KMS_KEY_ID?.trim()) && Boolean(env.AWS_REGION?.trim());
  const checks: HealthCheck[] = [
    postgres,
    clickhouse,
    {
      name: "analytics_config",
      ok: analyticsConfigured,
      critical: false,
      ...(analyticsConfigured ? {} : { reason: "missing_project_key_or_scope_secret" }),
    },
    {
      name: "kms_config",
      ok: kmsConfigured,
      critical: true,
      ...(kmsConfigured ? {} : { reason: "missing_kms_key_id_or_region" }),
    },
  ];
  const status: HealthStatus = checks.some((check) => !check.ok && check.critical)
    ? "down"
    : checks.some((check) => !check.ok)
    ? "degraded"
    : "ok";
  return { status, checks, checkedAt: new Date().toISOString() };
}

async function timed(
  name: HealthCheck["name"],
  critical: boolean,
  timeoutMs: number,
  run: () => Promise<{ ok: true } | { ok: false; reason: string }>,
): Promise<HealthCheck> {
  const startedAt = performance.now();
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<{ ok: false; reason: string }>((resolve) => {
    timer = setTimeout(() => resolve({ ok: false, reason: "timeout" }), timeoutMs);
  });
  try {
    const result = await Promise.race([
      run().catch((error: unknown) => ({ ok: false as const, reason: reasonOf(error) })),
      timeout,
    ]);
    const latencyMs = Math.round(performance.now() - startedAt);
    return result.ok
      ? { name, ok: true, critical, latencyMs }
      : { name, ok: false, critical, latencyMs, reason: result.reason };
  } finally {
    if (timer) clearTimeout(timer);
  }
}

/** Error class name only; messages can embed hosts or credentials. */
function reasonOf(error: unknown): string {
  return error instanceof Error && error.name ? error.name.slice(0, 80) : "error";
}
