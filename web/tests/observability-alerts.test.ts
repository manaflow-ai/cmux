import { describe, expect, mock, test } from "bun:test";
import { sendAlert } from "../services/observability/alerts";
import { GET as vmAlertsCronGET } from "../app/api/cron/vm-alerts/route";

describe("observability alerts", () => {
  test("sendAlert no-ops when the Slack webhook is unset", async () => {
    const fetchMock = mock(async () => {
      throw new Error("fetch should not be called");
    }) as unknown as typeof fetch;

    const result = await sendAlert({
      key: "test-alert",
      title: "Test alert",
      body: "This should not send.",
      severity: "warning",
    }, {
      env: {},
      fetch: fetchMock,
    });

    expect(result).toEqual({ sent: false });
    expect(fetchMock).not.toHaveBeenCalled();
  });

  test("sendAlert formats one Slack webhook message", async () => {
    const fetchMock = mock(async (...args: unknown[]) => {
      const init = args[1] as RequestInit | undefined;
      const payload = JSON.parse(String(init?.body)) as { text: string };
      expect(payload.text).toBe("🔴 Alert title\nAlert body");
      return new Response("ok", { status: 200 });
    }) as unknown as typeof fetch;

    const result = await sendAlert({
      key: "test-alert",
      title: "Alert title",
      body: "Alert body",
      severity: "critical",
    }, {
      env: { CMUX_ALERTS_SLACK_WEBHOOK_URL: "https://hooks.slack.test/services/test" },
      fetch: fetchMock,
    });

    expect(result).toEqual({ sent: true, status: 200 });
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  test("VM alerts cron requires CRON_SECRET and bearer auth before querying", async () => {
    const previous = process.env.CRON_SECRET;
    try {
      delete process.env.CRON_SECRET;
      const notConfigured = await vmAlertsCronGET(
        new Request("https://cmux.test/api/cron/vm-alerts"),
      );
      expect(notConfigured.status).toBe(503);

      process.env.CRON_SECRET = "cron-secret";
      const missingBearer = await vmAlertsCronGET(
        new Request("https://cmux.test/api/cron/vm-alerts"),
      );
      expect(missingBearer.status).toBe(401);

      const unauthorized = await vmAlertsCronGET(
        new Request("https://cmux.test/api/cron/vm-alerts", {
          headers: { authorization: "Bearer wrong-secret" },
        }),
      );
      expect(unauthorized.status).toBe(401);
    } finally {
      if (previous === undefined) {
        delete process.env.CRON_SECRET;
      } else {
        process.env.CRON_SECRET = previous;
      }
    }
  });
});
