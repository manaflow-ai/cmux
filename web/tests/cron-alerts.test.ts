import { describe, expect, mock, test } from "bun:test";
import { runCronAlertChecks } from "../services/observability/cronAlerts";
import type { AlertInput } from "../services/observability/alerts";

function axiomResponse(groups: Array<{ name: string; code: string; count: number }>) {
  return new Response(
    JSON.stringify({
      buckets: {
        series: [
          {
            groups: groups.map((g) => ({
              group: { name: g.name, code: g.code },
              aggregations: [{ value: g.count }],
            })),
          },
        ],
      },
    }),
    { status: 200, headers: { "content-type": "application/json" } },
  );
}

describe("cron alert checks", () => {
  test("a 5xx on any cron or internal route in the last hour warns with the route list", async () => {
    const sent: AlertInput[] = [];
    const fetch = mock(async (_input: unknown, init?: RequestInit) => {
      const body = JSON.parse(String(init?.body));
      expect(body.apl).toContain("/api/cron/");
      expect(body.apl).toContain("/api/internal/");
      return axiomResponse([
        { name: "GET /api/cron/vm-reconcile", code: "500", count: 2 },
        { name: "GET /api/internal/iroh/retention", code: "200", count: 6 },
      ]);
    });
    const summary = await runCronAlertChecks({
      env: { CMUX_AXIOM_READ_TOKEN: "t", CMUX_AXIOM_TRACES_DATASET: "cmux-prod-otel-traces" },
      fetch: fetch as never,
      sendAlert: async (input) => { sent.push(input); return { sent: true, configured: true }; },
    });
    expect(summary.configured).toBe(true);
    expect(summary.failures).toEqual({ triggered: true, count: 2 });
    expect(sent).toHaveLength(1);
    expect(sent[0]?.key).toBe("cron-route-failures");
    expect(sent[0]?.body).toContain("GET /api/cron/vm-reconcile: 2");
    expect(sent[0]?.body).not.toContain("retention");
  });

  test("without a read token the check reports unconfigured and sends nothing", async () => {
    const sent: AlertInput[] = [];
    const summary = await runCronAlertChecks({
      env: {},
      fetch: mock(async () => { throw new Error("must not be called"); }) as never,
      sendAlert: async (input) => { sent.push(input); return { sent: true, configured: true }; },
    });
    expect(summary.configured).toBe(false);
    expect(sent).toHaveLength(0);
  });

  test("an Axiom outage does not itself page and does not throw", async () => {
    const sent: AlertInput[] = [];
    const summary = await runCronAlertChecks({
      env: { CMUX_AXIOM_READ_TOKEN: "t" },
      fetch: mock(async () => new Response("nope", { status: 503 })) as never,
      sendAlert: async (input) => { sent.push(input); return { sent: true, configured: true }; },
    });
    expect(summary.configured).toBe(true);
    expect(summary.queryFailed).toBe(true);
    expect(sent).toHaveLength(0);
  });
});
