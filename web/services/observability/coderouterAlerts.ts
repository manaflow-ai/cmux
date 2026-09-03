// Coderouter alert checks, run by `/api/cron/coderouter-alerts` every five
// minutes. Sources: the ClickHouse `route_events` ledger (one row per routed
// request, written by the data plane) and the dependency health probe. Every
// triggered alert goes to Slack through `sendAlert`; with no webhook it is
// recorded as a PostHog `coderouter_alert` (dropped) so the silence is visible.
//
// Windows are aligned to the cron so a burst fires once, not three times:
// spike checks look at the last five minutes. Slack has no dedupe, so a
// persistent condition repeats every run; that is the intended behaviour for
// `critical` (an outage should stay loud) and the reason `warning` checks
// use higher thresholds.
import { captureCoderouterRawBatch } from "../coderouter/analytics";
import { query as clickHouseQuery, type ClickHouseDependencies } from "../coderouter/clickhouse";
import { coderouterHealth, type CoderouterHealth } from "../coderouter/health";
import { reportCoderouterFailure } from "../coderouter/observability";
import { sendAlert, type AlertFetch, type AlertInput, type AlertResult } from "./alerts";

export const CODEROUTER_ALERT_WINDOW_MINUTES = 5;

export type CoderouterAlertCheck = {
  readonly key: string;
  readonly triggered: boolean;
  readonly count: number;
  readonly threshold: number;
};

export type CoderouterAlertSummary = {
  readonly health: CoderouterHealth["status"];
  readonly ledgerReachable: boolean;
  readonly checks: readonly CoderouterAlertCheck[];
  readonly alertSink: {
    readonly configured: boolean;
    readonly droppedAlerts: number;
    readonly sent: number;
    readonly deliveryFailures: number;
  };
};

type RouteEventRow = {
  readonly outcome: string;
  readonly failure_stage: string;
  readonly team_id: string;
  readonly provider: string;
  readonly c: number;
};

export type CoderouterAlertDependencies = {
  readonly env?: Record<string, string | undefined>;
  readonly fetch?: AlertFetch;
  readonly sendAlert?: (input: AlertInput) => Promise<AlertResult>;
  readonly health?: () => Promise<CoderouterHealth>;
  readonly routeEvents?: (windowMinutes: number) => Promise<
    | { ok: true; rows: RouteEventRow[] }
    | { ok: false; reason: string }
  >;
  readonly clickHouse?: ClickHouseDependencies;
  /** Injectable sinks make the unconfigured-alert path observable in tests. */
  readonly captureRawBatch?: typeof captureCoderouterRawBatch;
  readonly reportFailure?: typeof reportCoderouterFailure;
};

const ROUTE_EVENTS_SQL = `
SELECT outcome, failure_stage, team_id, provider, count() AS c
FROM {db}.route_events
WHERE event_time > now() - INTERVAL {window:UInt16} MINUTE
GROUP BY outcome, failure_stage, team_id, provider
`;

async function loadRouteEvents(
  windowMinutes: number,
  clickHouse?: ClickHouseDependencies,
): Promise<{ ok: true; rows: RouteEventRow[] } | { ok: false; reason: string }> {
  const result = await clickHouseQuery<RouteEventRow>(
    ROUTE_EVENTS_SQL,
    { window: windowMinutes },
    clickHouse,
  );
  if (!result.ok) {
    return { ok: false, reason: result.reason === "status" ? `http_${result.status}` : result.reason };
  }
  return { ok: true, rows: result.rows.map((row) => ({ ...row, c: Number(row.c) })) };
}

export async function runCoderouterAlertChecks(
  dependencies: CoderouterAlertDependencies = {},
): Promise<CoderouterAlertSummary> {
  const env = dependencies.env ?? process.env;
  const rawSend = dependencies.sendAlert ?? ((input: AlertInput) => sendAlert(input, { fetch: dependencies.fetch, env }));
  const configured = Boolean(env.CMUX_ALERTS_SLACK_WEBHOOK_URL?.trim());
  const dropped: AlertInput[] = [];
  let sent = 0;
  let deliveryFailures = 0;
  const send = async (input: AlertInput) => {
    try {
      const result = await rawSend(input);
      if (result.configured === false) dropped.push(input);
      else if (result.sent) sent += 1;
      else deliveryFailures += 1;
    } catch {
      // A custom sender is allowed to throw. Keep the cron result truthful and
      // prevent one failed webhook from suppressing the remaining checks.
      deliveryFailures += 1;
    }
  };

  const thresholds = {
    operatorFailures: positiveIntegerEnv(env.CMUX_CODEROUTER_ALERT_OPERATOR_FAILURES_5M, 1),
    upstreamFailures: positiveIntegerEnv(env.CMUX_CODEROUTER_ALERT_UPSTREAM_FAILURES_5M, 5),
    noUsableAccount: positiveIntegerEnv(env.CMUX_CODEROUTER_ALERT_NO_ACCOUNT_5M, 10),
    authRejected: positiveIntegerEnv(env.CMUX_CODEROUTER_ALERT_AUTH_REJECTED_5M, 25),
  };

  const health = await (dependencies.health ?? coderouterHealth)().catch((error: unknown): CoderouterHealth => {
    reportCoderouterFailure("health_check", error);
    return {
      status: "down",
      checks: [{ name: "postgres", ok: false, critical: true, reason: "probe_failed" }],
      checkedAt: new Date().toISOString(),
    };
  });
  if (health.status !== "ok") {
    const failing = health.checks.filter((check) => !check.ok);
    await send({
      key: "coderouter-health",
      title: health.status === "down" ? "coderouter is down" : "coderouter is degraded",
      body: failing.map((check) => `${check.name}: ${check.reason ?? "failed"}`).join("; "),
      severity: health.status === "down" ? "critical" : "warning",
    });
  }

  const events = await (dependencies.routeEvents ?? ((minutes) => loadRouteEvents(minutes, dependencies.clickHouse)))(
    CODEROUTER_ALERT_WINDOW_MINUTES,
  );
  const checks: CoderouterAlertCheck[] = [];
  if (!events.ok) {
    // The ledger is also the customer's usage source, so an unreachable
    // ClickHouse is an incident even when routing still works. The health
    // probe already alerted when the config is missing or the ping failed;
    // this covers a reachable service that rejects the query.
    if (health.checks.find((check) => check.name === "clickhouse")?.ok !== false) {
      await send({
        key: "coderouter-ledger-unreachable",
        title: "coderouter usage ledger query failed",
        body: `ClickHouse route_events query failed: ${events.reason}. Usage and alerts are dark.`,
        severity: "critical",
      });
    }
  } else {
    const rows = events.rows;
    const total = sum(rows);
    const operatorRows = rows.filter((row) => isOperatorFailure(row));
    const upstreamRows = rows.filter((row) => isUpstreamFailure(row));
    const noAccountRows = rows.filter((row) =>
      row.outcome === "no_usable_account" &&
      (row.failure_stage === "account_selection" || row.failure_stage === "provider_config"));
    const authRows = rows.filter((row) => row.outcome === "unauthorized");
    const evaluate = async (
      key: string,
      count: number,
      threshold: number,
      alert: () => Omit<AlertInput, "key">,
    ): Promise<void> => {
      const triggered = count >= threshold;
      checks.push({ key, triggered, count, threshold });
      if (triggered) await send({ key, ...alert() });
    };

    const operatorCount = sum(operatorRows);
    await evaluate("coderouter-operator-failures", operatorCount, thresholds.operatorFailures, () => ({
      title: "coderouter failed requests on our side",
      body: [
        `${operatorCount} of ${total} routed requests in the last ${CODEROUTER_ALERT_WINDOW_MINUTES} minutes failed before reaching a provider`,
        `(${describe(operatorRows)}).`,
        "Check RDS, KMS and the Vercel deploy; search PostHog Error Tracking for coderouter_provider_unavailable.",
      ].join(" "),
      severity: "critical",
    }));

    const upstreamCount = sum(upstreamRows);
    await evaluate("coderouter-upstream-failures", upstreamCount, thresholds.upstreamFailures, () => ({
      title: "coderouter upstream providers are failing",
      body: `${upstreamCount} of ${total} requests in the last ${CODEROUTER_ALERT_WINDOW_MINUTES} minutes ended in a provider failure after failover (${describe(upstreamRows)}).`,
      severity: "warning",
    }));

    const noAccountCount = sum(noAccountRows);
    await evaluate("coderouter-no-usable-account", noAccountCount, thresholds.noUsableAccount, () => {
      const teams = [...new Set(noAccountRows.map((row) => row.team_id).filter(Boolean))].slice(0, 10);
      return {
        title: "coderouter teams have no usable account",
        body: `${noAccountCount} requests in the last ${CODEROUTER_ALERT_WINDOW_MINUTES} minutes found no healthy account across ${teams.length} team(s): ${teams.join(", ") || "unknown"}.`,
        severity: "warning",
      };
    });

    const authCount = sum(authRows);
    await evaluate("coderouter-auth-rejected", authCount, thresholds.authRejected, () => ({
      title: "coderouter route tokens are being rejected",
      body: `${authCount} unauthorized requests in the last ${CODEROUTER_ALERT_WINDOW_MINUTES} minutes. A revoked edge token, a broken \`cr login\`, or a scan.`,
      severity: "warning",
    }));
  }

  if (dropped.length > 0) {
    reportDroppedCoderouterAlerts(dropped, env, {
      captureRawBatch: dependencies.captureRawBatch,
      reportFailure: dependencies.reportFailure,
    });
  }

  return {
    health: health.status,
    ledgerReachable: events.ok,
    checks,
    alertSink: { configured, droppedAlerts: dropped.length, sent, deliveryFailures },
  };
}

function isOperatorFailure(row: RouteEventRow): boolean {
  return row.outcome === "provider_unavailable" &&
    row.failure_stage !== "upstream_transport" &&
    row.failure_stage !== "upstream_response";
}

function isUpstreamFailure(row: RouteEventRow): boolean {
  if (row.outcome === "upstream_error") return true;
  if (row.outcome === "provider_unavailable") {
    return row.failure_stage === "upstream_transport" ||
      row.failure_stage === "upstream_response";
  }
  return row.outcome === "no_usable_account" &&
    (row.failure_stage === "credential_refresh" || row.failure_stage === "upstream_transport");
}

function sum(rows: readonly RouteEventRow[]): number {
  return rows.reduce((acc, row) => acc + (Number.isFinite(row.c) ? row.c : 0), 0);
}

function describe(rows: readonly RouteEventRow[]): string {
  const byKey = new Map<string, number>();
  for (const row of rows) {
    const key = `${row.provider}/${row.outcome}/${row.failure_stage}`;
    byKey.set(key, (byKey.get(key) ?? 0) + row.c);
  }
  return [...byKey.entries()]
    .sort((a, b) => b[1] - a[1])
    .slice(0, 5)
    .map(([key, count]) => `${key}: ${count}`)
    .join(", ") || "none";
}

/**
 * Alerts that fired with no Slack sink: one structured error (Sentry) and one
 * PostHog `coderouter_alert` event per key so an unconfigured production
 * deployment is visible in the tools that ARE configured.
 */
function reportDroppedCoderouterAlerts(
  alerts: readonly AlertInput[],
  env: Record<string, string | undefined>,
  dependencies: Pick<CoderouterAlertDependencies, "captureRawBatch" | "reportFailure"> = {},
): void {
  if (env.VERCEL_ENV !== "production" && env.CMUX_ALERTS_REPORT_FORCE !== "1") return;
  const keys = [...new Set(alerts.map((alert) => alert.key))];
  (dependencies.reportFailure ?? reportCoderouterFailure)(
    "alerts",
    new Error(`coderouter alerts fired with no Slack sink configured: ${keys.join(", ")}`),
    { dropped: keys.length },
  );
  (dependencies.captureRawBatch ?? captureCoderouterRawBatch)(alerts.map((alert) => ({
    event: "coderouter_alert" as const,
    properties: {
      alert_key: alert.key,
      severity: alert.severity,
      title: alert.title,
      coderouter_alert_dropped: true,
      window_minutes: CODEROUTER_ALERT_WINDOW_MINUTES,
    },
  })));
}

function positiveIntegerEnv(value: string | undefined, fallback: number): number {
  const trimmed = value?.trim();
  if (!trimmed || !/^\d+$/.test(trimmed)) return fallback;
  const parsed = Number(trimmed);
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : fallback;
}
