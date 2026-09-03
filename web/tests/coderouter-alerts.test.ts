import { describe, expect, test } from "bun:test";

import type { AlertInput, AlertResult } from "../services/observability/alerts";
import { runCoderouterAlertChecks } from "../services/observability/coderouterAlerts";
import type { CoderouterHealth } from "../services/coderouter/health";

const healthy: CoderouterHealth = {
  status: "ok",
  checks: [
    { name: "postgres", ok: true, critical: true, latencyMs: 3 },
    { name: "clickhouse", ok: true, critical: false, latencyMs: 40 },
    { name: "kms_config", ok: true, critical: true },
  ],
  checkedAt: "2026-09-03T00:00:00.000Z",
};

type Row = { outcome: string; failure_stage: string; team_id: string; provider: string; c: number };

function harness(rows: Row[] | { reason: string }, health: CoderouterHealth = healthy, env: Record<string, string> = {}) {
  const sent: AlertInput[] = [];
  const configured = "CMUX_ALERTS_SLACK_WEBHOOK_URL" in env;
  const run = () => runCoderouterAlertChecks({
    env,
    health: async () => health,
    routeEvents: async () => Array.isArray(rows) ? { ok: true, rows } : { ok: false, reason: rows.reason },
    sendAlert: async (input): Promise<AlertResult> => {
      sent.push(input);
      return configured ? { sent: true, configured: true, status: 200 } : { sent: false, configured: false };
    },
  });
  return { sent, run };
}

const webhook = { CMUX_ALERTS_SLACK_WEBHOOK_URL: "https://hooks.slack.test/x" };

describe("coderouter alert checks", () => {
  test("a healthy quiet window sends nothing", async () => {
    const { sent, run } = harness([
      { outcome: "success", failure_stage: "none", team_id: "t1", provider: "codex", c: 12 },
      { outcome: "unauthorized", failure_stage: "auth", team_id: "", provider: "claude", c: 2 },
    ], healthy, webhook);
    const summary = await run();
    expect(sent).toEqual([]);
    expect(summary.health).toBe("ok");
    expect(summary.ledgerReachable).toBe(true);
    expect(summary.checks.every((check) => !check.triggered)).toBe(true);
    expect(summary.alertSink).toEqual({ configured: true, droppedAlerts: 0, sent: 0 });
  });

  test("one operator-side failure is critical; upstream and tenant failures need their thresholds", async () => {
    const { sent, run } = harness([
      { outcome: "provider_unavailable", failure_stage: "account_selection", team_id: "t1", provider: "claude", c: 1 },
      { outcome: "upstream_error", failure_stage: "upstream_response", team_id: "t1", provider: "codex", c: 2 },
      { outcome: "no_usable_account", failure_stage: "account_selection", team_id: "t2", provider: "codex", c: 3 },
    ], healthy, webhook);
    const summary = await run();
    expect(sent.map((alert) => alert.key)).toEqual(["coderouter-operator-failures"]);
    expect(sent[0]!.severity).toBe("critical");
    expect(sent[0]!.body).toContain("claude/provider_unavailable/account_selection: 1");
    expect(summary.checks.find((check) => check.key === "coderouter-upstream-failures")).toMatchObject({ triggered: false, count: 2, threshold: 5 });
    expect(summary.checks.find((check) => check.key === "coderouter-no-usable-account")).toMatchObject({ triggered: false, count: 3, threshold: 10 });
  });

  test("upstream failures across providers aggregate into one warning and list the breakdown", async () => {
    const { sent, run } = harness([
      { outcome: "upstream_error", failure_stage: "upstream_response", team_id: "t1", provider: "codex", c: 3 },
      { outcome: "no_usable_account", failure_stage: "upstream_transport", team_id: "t1", provider: "codex", c: 1 },
      { outcome: "provider_unavailable", failure_stage: "upstream_transport", team_id: "t3", provider: "opencode-go", c: 1 },
      { outcome: "success", failure_stage: "none", team_id: "t1", provider: "codex", c: 5 },
    ], healthy, { ...webhook, CMUX_CODEROUTER_ALERT_UPSTREAM_FAILURES_5M: "5" });
    await run();
    expect(sent.map((alert) => alert.key)).toEqual(["coderouter-upstream-failures"]);
    expect(sent[0]!.severity).toBe("warning");
    expect(sent[0]!.body).toContain("5 of 10 requests");
    expect(sent[0]!.body).toContain("codex/upstream_error/upstream_response: 3");
  });

  test("tenants without a usable account are named, auth rejects use their own threshold", async () => {
    const { sent, run } = harness([
      { outcome: "no_usable_account", failure_stage: "account_selection", team_id: "team-a", provider: "codex", c: 6 },
      { outcome: "no_usable_account", failure_stage: "provider_config", team_id: "team-b", provider: "claude", c: 4 },
      { outcome: "unauthorized", failure_stage: "auth", team_id: "", provider: "codex", c: 30 },
    ], healthy, webhook);
    await run();
    expect(sent.map((alert) => alert.key)).toEqual(["coderouter-no-usable-account", "coderouter-auth-rejected"]);
    expect(sent[0]!.body).toContain("team-a, team-b");
    expect(sent[1]!.body).toContain("30 unauthorized requests");
  });

  test("a degraded or down health probe alerts with the failing checks", async () => {
    const down: CoderouterHealth = {
      ...healthy,
      status: "down",
      checks: [
        { name: "postgres", ok: false, critical: true, reason: "timeout" },
        { name: "clickhouse", ok: false, critical: false, reason: "not_configured" },
            { name: "kms_config", ok: true, critical: true },
      ],
    };
    const { sent, run } = harness([], down, webhook);
    const summary = await run();
    expect(sent[0]).toMatchObject({ key: "coderouter-health", severity: "critical", title: "coderouter is down" });
    expect(sent[0]!.body).toBe("postgres: timeout; clickhouse: not_configured");
    expect(summary.health).toBe("down");
  });

  test("a failed ledger query is critical unless the health probe already reported ClickHouse", async () => {
    const first = harness({ reason: "http_500" }, healthy, webhook);
    const summary = await first.run();
    expect(first.sent.map((alert) => alert.key)).toEqual(["coderouter-ledger-unreachable"]);
    expect(summary.ledgerReachable).toBe(false);
    expect(summary.checks).toEqual([]);

    const degraded: CoderouterHealth = {
      ...healthy,
      status: "degraded",
      checks: healthy.checks.map((check) => check.name === "clickhouse" ? { ...check, ok: false, reason: "timeout" } : check),
    };
    const second = harness({ reason: "request_failed" }, degraded, webhook);
    await second.run();
    expect(second.sent.map((alert) => alert.key)).toEqual(["coderouter-health"]);
  });

  test("with no Slack sink the triggered alerts are counted as dropped", async () => {
    const { sent, run } = harness([
      { outcome: "provider_unavailable", failure_stage: "account_selection", team_id: "t1", provider: "codex", c: 2 },
    ], healthy, {});
    const summary = await run();
    expect(sent.length).toBe(1);
    expect(summary.alertSink).toEqual({ configured: false, droppedAlerts: 1, sent: 0 });
  });
});
