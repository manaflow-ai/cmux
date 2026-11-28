import { sendAlert, type AlertFetch, type AlertInput, type AlertResult } from "./alerts";

/**
 * Cron and internal routes fail silently: Vercel retries nothing and the
 * trace sampler used to keep 2 percent of them. This check reads the last
 * hour of traces from Axiom and pages once per run with the failing routes.
 *
 * Needs `CMUX_AXIOM_READ_TOKEN` (an Axiom API token with query access) and
 * optionally `CMUX_AXIOM_TRACES_DATASET`; without the token the check is
 * reported as unconfigured rather than failing the cron.
 */
export type CronAlertSummary = {
  readonly configured: boolean;
  readonly queryFailed: boolean;
  readonly failures: { readonly triggered: boolean; readonly count: number };
};

const DEFAULT_DATASET = "cmux-prod-otel-traces";
const WINDOW_MINUTES = 65;

export async function runCronAlertChecks(options: {
  readonly env?: Record<string, string | undefined>;
  readonly now?: Date;
  readonly fetch?: AlertFetch;
  readonly sendAlert?: (input: AlertInput) => Promise<AlertResult>;
} = {}): Promise<CronAlertSummary> {
  const env = options.env ?? process.env;
  const now = options.now ?? new Date();
  const token = env.CMUX_AXIOM_READ_TOKEN?.trim();
  const send = options.sendAlert ?? ((input) => sendAlert(input, { fetch: options.fetch, env }));
  if (!token) {
    return { configured: false, queryFailed: false, failures: { triggered: false, count: 0 } };
  }
  const dataset = env.CMUX_AXIOM_TRACES_DATASET?.trim() || DEFAULT_DATASET;
  const doFetch: AlertFetch = options.fetch ?? fetch;
  const apl = [
    `['${dataset}']`,
    `| where _time > ago(${WINDOW_MINUTES}m)`,
    "| where name startswith 'GET /api/cron/' or name startswith 'POST /api/cron/' or name startswith 'GET /api/internal/' or name startswith 'POST /api/internal/'",
    "| extend code = tostring(['attributes.custom']['http.status_code'])",
    "| summarize c=count() by name, code",
  ].join(" ");
  let failing: Array<{ route: string; count: number }>;
  try {
    const response = await doFetch("https://api.axiom.co/v1/datasets/_apl?format=legacy", {
      method: "POST",
      headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
      body: JSON.stringify({
        apl,
        startTime: new Date(now.getTime() - WINDOW_MINUTES * 60_000).toISOString(),
        endTime: now.toISOString(),
      }),
    });
    if (!response.ok) throw new Error(`axiom query ${response.status}`);
    failing = parseFailingRoutes(await response.json());
  } catch (error) {
    console.warn("observability.cron_alerts.query_failed", {
      message: error instanceof Error ? error.message : String(error),
    });
    return { configured: true, queryFailed: true, failures: { triggered: false, count: 0 } };
  }
  const total = failing.reduce((sum, row) => sum + row.count, 0);
  if (total > 0) {
    await send({
      key: "cron-route-failures",
      title: "Cron or internal routes returned 5xx",
      body: [
        `${total} failed run(s) in the last ${WINDOW_MINUTES} minutes:`,
        failing.map((row) => `${row.route}: ${row.count}`).join(", ") + ".",
      ].join(" "),
      severity: "warning",
    });
  }
  return { configured: true, queryFailed: false, failures: { triggered: total > 0, count: total } };
}

function parseFailingRoutes(payload: unknown): Array<{ route: string; count: number }> {
  const series = (payload as { buckets?: { series?: unknown[] } })?.buckets?.series ?? [];
  const out = new Map<string, number>();
  for (const s of series as Array<{ groups?: unknown[] }>) {
    for (const g of s.groups ?? []) {
      const group = (g as { group?: Record<string, unknown>; aggregations?: Array<{ value?: unknown }> });
      const name = String(group.group?.name ?? "");
      const code = String(group.group?.code ?? "");
      const value = Number(group.aggregations?.[0]?.value ?? 0);
      if (!name || !/^5\d\d$/.test(code) || !Number.isFinite(value) || value <= 0) continue;
      out.set(name, (out.get(name) ?? 0) + value);
    }
  }
  return [...out.entries()].map(([route, count]) => ({ route, count })).sort((a, b) => b.count - a.count);
}
