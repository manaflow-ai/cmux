// Coderouter dependency health, for `GET /api/coderouter/health` (uptime
// monitors) and the alert cron. Each check is bounded and reports a status,
// never a value: no connection string, key id, or host name leaves the
// process. `degraded` means the data plane still routes but the usage ledger
// is dark; `down` means requests would fail.
import { pingCloudDb } from "../../db/client";
import { clickHouseConfig, query as clickHouseQuery } from "./clickhouse";
import { addCoderouterBreadcrumb } from "./observability";
import { errorSummary } from "./exceptionEvent";

export type HealthStatus = "ok" | "degraded" | "down";

export type HealthCheck = {
  readonly name: "postgres" | "clickhouse" | "kms_config";
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
  /** Implementations must honor the signal and settle within timeoutMs. */
  readonly pingPostgres: (signal: AbortSignal, timeoutMs: number) => Promise<void>;
  /** Implementations must honor the signal and settle within timeoutMs. */
  readonly pingClickHouse: (signal: AbortSignal, timeoutMs: number) => Promise<{ ok: true } | { ok: false; reason: string }>;
  readonly env: Record<string, string | undefined>;
  readonly timeoutMs: number;
  /** Injectable clock keeps timeout tests deterministic without wall time. */
  readonly scheduler?: HealthScheduler;
};

export type HealthScheduler = {
  readonly now: () => number;
  readonly setTimeout: (callback: () => void, timeoutMs: number) => unknown;
  readonly clearTimeout: (handle: unknown) => void;
};

const defaultHealthScheduler: HealthScheduler = {
  now: () => performance.now(),
  setTimeout: (callback, timeoutMs) => setTimeout(callback, timeoutMs),
  clearTimeout: (handle) => clearTimeout(handle as ReturnType<typeof setTimeout>),
};

export const HEALTH_CHECK_TIMEOUT_MS = 4_000;

export const defaultHealthDependencies: HealthDependencies = {
  pingPostgres: (signal, timeoutMs) => pingCloudDb(signal, timeoutMs),
  pingClickHouse: async (signal, timeoutMs) => {
    if (!clickHouseConfig()) return { ok: false, reason: "not_configured" };
    const result = await clickHouseQuery<{ one: number }>("SELECT 1 AS one", {}, undefined, {
      signal,
      timeoutMs,
    });
    if (result.ok) return { ok: true };
    return { ok: false, reason: result.reason === "status" ? `http_${result.status}` : result.reason };
  },
  env: process.env,
  timeoutMs: HEALTH_CHECK_TIMEOUT_MS,
  scheduler: defaultHealthScheduler,
};

export async function coderouterHealth(
  dependencies: HealthDependencies = defaultHealthDependencies,
): Promise<CoderouterHealth> {
  const scheduler = dependencies.scheduler ?? defaultHealthScheduler;
  const [postgres, clickhouse] = await Promise.all([
    timed("postgres", true, dependencies.timeoutMs, scheduler, async (signal, timeoutMs) => {
      await dependencies.pingPostgres(signal, timeoutMs);
      return { ok: true as const };
    }),
    timed("clickhouse", false, dependencies.timeoutMs, scheduler, dependencies.pingClickHouse),
  ]);
  const env = dependencies.env;
  const kmsConfigured = Boolean(env.CODEROUTER_KMS_KEY_ID?.trim()) && Boolean(env.AWS_REGION?.trim());
  const checks: HealthCheck[] = [
    postgres,
    clickhouse,
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
  scheduler: HealthScheduler,
  run: (signal: AbortSignal, timeoutMs: number) => Promise<{ ok: true } | { ok: false; reason: string }>,
): Promise<HealthCheck> {
  const startedAt = scheduler.now();
  let timer: unknown;
  let didTimeout = false;
  const controller = new AbortController();
  const timeout = new Promise<{ ok: false; reason: string }>((resolve) => {
    timer = scheduler.setTimeout(() => {
      didTimeout = true;
      controller.abort();
      resolve({ ok: false, reason: "timeout" });
    }, timeoutMs);
  });
  const operation = Promise.resolve()
    .then(() => run(controller.signal, timeoutMs))
    .catch((error: unknown) => {
      addCoderouterBreadcrumb("health", "Dependency probe failed", {
        dependency: name,
        error_type: reasonOf(error),
      }, "error");
      return { ok: false as const, reason: "probe_failed" };
    });
  try {
    const raced = await Promise.race([operation, timeout]);
    const result = didTimeout ? { ok: false as const, reason: "timeout" } : raced;
    const latencyMs = Math.round(scheduler.now() - startedAt);
    return result.ok
      ? { name, ok: true, critical, latencyMs }
      : { name, ok: false, critical, latencyMs, reason: result.reason };
  } finally {
    if (timer !== undefined) scheduler.clearTimeout(timer);
    controller.abort();
  }
}

/** Error class name only; messages can embed hosts or credentials. */
function reasonOf(error: unknown): string {
  const summary = errorSummary(error);
  return summary.slice(0, summary.indexOf(":") > 0 ? summary.indexOf(":") : summary.length);
}
