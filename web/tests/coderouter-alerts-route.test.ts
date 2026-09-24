import { describe, expect, test } from "bun:test";

import {
  handleCoderouterAlertsCron,
  type CoderouterAlertCronRunner,
} from "../app/api/cron/coderouter-alerts/route";
import type { CoderouterAlertSummary } from "../services/observability/coderouterAlerts";

const summary: CoderouterAlertSummary = {
  health: "ok",
  ledgerReachable: true,
  checks: [],
  alertSink: {
    configured: true,
    droppedAlerts: 0,
    sent: 0,
    deliveryFailures: 0,
  },
};

function runner(value: CoderouterAlertSummary): CoderouterAlertCronRunner {
  return async () => value;
}

function withEnv(values: Record<string, string | undefined>, run: () => Promise<void>): Promise<void> {
  const previous = new Map<string, string | undefined>();
  for (const [key, value] of Object.entries(values)) {
    previous.set(key, process.env[key]);
    if (value === undefined) delete process.env[key];
    else process.env[key] = value;
  }
  return run().finally(() => {
    for (const [key, value] of previous) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
  });
}

describe("coderouter alerts cron route", () => {
  test("fails closed when CRON_SECRET is not configured", async () => {
    let ran = false;
    await withEnv({
      CRON_SECRET: undefined,
      CMUX_ALERTS_SLACK_WEBHOOK_URL: "https://hooks.slack.test/x",
      CMUX_ALERTS_SINK_UNCONFIGURED_ACK: undefined,
    }, async () => {
      const response = await handleCoderouterAlertsCron(
        new Request("https://cmux.test/api/cron/coderouter-alerts", {
          headers: { authorization: "Bearer cron-secret" },
        }),
        async () => {
          ran = true;
          return summary;
        },
      );
      expect(response.status).toBe(503);
      expect(await response.json()).toEqual({ error: "cron_not_configured" });
    });
    expect(ran).toBe(false);
  });

  test("rejects a request without the Vercel bearer header before running checks", async () => {
    let ran = false;
    await withEnv({
      CRON_SECRET: "cron-secret",
      CMUX_ALERTS_SLACK_WEBHOOK_URL: "https://hooks.slack.test/x",
      CMUX_ALERTS_SINK_UNCONFIGURED_ACK: undefined,
    }, async () => {
      const response = await handleCoderouterAlertsCron(
        new Request("https://cmux.test/api/cron/coderouter-alerts"),
        async () => {
          ran = true;
          return summary;
        },
      );
      expect(response.status).toBe(401);
      expect(await response.json()).toEqual({ error: "unauthorized" });
    });
    expect(ran).toBe(false);
  });

  test("fails before running checks when neither Slack nor a waiver is configured", async () => {
    let ran = false;
    await withEnv({
      CRON_SECRET: "cron-secret",
      CMUX_ALERTS_SLACK_WEBHOOK_URL: undefined,
      CMUX_ALERTS_SINK_UNCONFIGURED_ACK: undefined,
    }, async () => {
      const response = await handleCoderouterAlertsCron(
        new Request("https://cmux.test/api/cron/coderouter-alerts", {
          headers: { authorization: "Bearer cron-secret" },
        }),
        async () => {
          ran = true;
          return summary;
        },
      );
      expect(response.status).toBe(503);
      expect(await response.json()).toEqual({
        configured: false,
        error: "alert_sink_not_configured",
      });
    });
    expect(ran).toBe(false);
  });

  test("returns a failure when a configured Slack delivery fails", async () => {
    await withEnv({
      CRON_SECRET: "cron-secret",
      CMUX_ALERTS_SLACK_WEBHOOK_URL: "https://hooks.slack.test/x",
      CMUX_ALERTS_SINK_UNCONFIGURED_ACK: undefined,
    }, async () => {
      const response = await handleCoderouterAlertsCron(
        new Request("https://cmux.test/api/cron/coderouter-alerts", {
          headers: { authorization: "Bearer cron-secret" },
        }),
        runner({
          ...summary,
          alertSink: { ...summary.alertSink, deliveryFailures: 1 },
        }),
      );
      expect(response.status).toBe(503);
      expect(await response.json()).toMatchObject({
        configured: true,
        error: "alert_delivery_failed",
      });
    });
  });
});
