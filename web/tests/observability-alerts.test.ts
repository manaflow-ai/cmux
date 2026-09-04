import { describe, expect, mock, test } from "bun:test";
import { cloudDb } from "../db/client";
import { sendAlert, type AlertInput, type AlertResult } from "../services/observability/alerts";
import { reportDroppedVmAlerts, runVmAlertChecks } from "../services/observability/vmAlerts";
import { GET as vmAlertsCronGET } from "../app/api/cron/vm-alerts/route";

function deferred<T>() {
  let resolve!: (value: T | PromiseLike<T>) => void;
  const promise = new Promise<T>((resolvePromise) => {
    resolve = resolvePromise;
  });
  return { promise, resolve };
}

function fakeAlertDb(): ReturnType<typeof cloudDb> {
  let queryNumber = 0;
  return {
    select: () => ({
      from: () => ({
        where: () => {
          queryNumber += 1;
          const rows = queryNumber === 1
            ? [{ total: 1, providers: ["freestyle"] }]
            : queryNumber === 2
              ? []
              : [{ total: 0 }];
          return Object.assign(Promise.resolve(rows), {
            limit: async () => [],
          });
        },
      }),
    }),
  } as unknown as ReturnType<typeof cloudDb>;
}

function alertInput(key: string): AlertInput {
  return { key, title: "Test alert", body: "Test body", severity: "warning" };
}

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

    expect(result).toEqual({ sent: false, configured: false });
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

    expect(result).toEqual({ sent: true, configured: true, status: 200 });
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  test("dropped alerts emit a PostHog operator-fault event in production", async () => {
    const seen: { body: Record<string, unknown> | null } = { body: null };
    const fetchMock = (async (...args: unknown[]) => {
      const init = args[1] as RequestInit | undefined;
      seen.body = JSON.parse(String(init?.body)) as Record<string, unknown>;
      return new Response("ok", { status: 200 });
    }) as unknown as typeof fetch;

    await reportDroppedVmAlerts(
      [{ key: "vm-create-failure-spike", title: "t", body: "b", severity: "critical" }],
      { env: { VERCEL_ENV: "production" }, fetch: fetchMock },
    );

    expect(seen.body?.event).toBe("cloud_vm_alert_dropped");
    expect(seen.body?.distinct_id).toBe("cmux-vm-alerts");
    const properties = seen.body?.properties as Record<string, unknown>;
    expect(properties.operator_fault).toBe(true);
    expect(properties.alert_keys).toEqual(["vm-create-failure-spike"]);
    expect(properties.alert_count).toBe(1);
  });

  test("dropped alert reporting resolves after the PostHog request settles", async () => {
    const request = deferred<Response>();
    const started = deferred<void>();
    const fetchMock = mock(async () => {
      started.resolve();
      return request.promise;
    }) as unknown as typeof fetch;

    const report = Promise.resolve(reportDroppedVmAlerts(
      [alertInput("vm-create-failure-spike")],
      { env: { VERCEL_ENV: "production" }, fetch: fetchMock },
    ));
    await started.promise;

    let settled = false;
    report.then(() => {
      settled = true;
    });
    await Promise.resolve();
    expect(settled).toBe(false);

    request.resolve(new Response("ok"));
    await report;
    expect(settled).toBe(true);
  });

  test("runVmAlertChecks waits for dropped-alert telemetry", async () => {
    const request = deferred<Response>();
    const started = deferred<void>();
    const fetchMock = mock(async () => {
      started.resolve();
      return request.promise;
    }) as unknown as typeof fetch;

    const checks = runVmAlertChecks({
      db: fakeAlertDb(),
      now: new Date("2026-08-31T12:00:00.000Z"),
      env: {
        VERCEL_ENV: "production",
        CMUX_VM_ALERT_CREATE_FAILURES_15M: "1",
      },
      fetch: fetchMock,
      sendAlert: async (): Promise<AlertResult> => ({
        sent: false,
        configured: false,
      }),
    });
    await started.promise;

    let settled = false;
    checks.then(() => {
      settled = true;
    });
    await Promise.resolve();
    expect(settled).toBe(false);

    request.resolve(new Response("ok"));
    const summary = await checks;
    expect(settled).toBe(true);
    expect(summary.alertSink).toEqual({ configured: false, droppedAlerts: 1 });
  });

  test("dropped alerts use stable per-key insert IDs within a daily bucket", async () => {
    const captures: Array<{ properties: Record<string, unknown> }> = [];
    const fetchMock = mock(async (...args: unknown[]) => {
      const init = args[1] as RequestInit | undefined;
      const payload = JSON.parse(String(init?.body)) as {
        properties: Record<string, unknown>;
      };
      captures.push(payload);
      return new Response("ok");
    }) as unknown as typeof fetch;
    const firstNow = new Date("2026-08-31T12:00:00.000Z");

    const firstOptions = { env: { VERCEL_ENV: "production" }, fetch: fetchMock, now: firstNow };
    const secondOptions = {
      env: { VERCEL_ENV: "production" },
      fetch: fetchMock,
      now: new Date(firstNow.getTime() + 60 * 60 * 1000),
    };
    const nextDayOptions = {
      env: { VERCEL_ENV: "production" },
      fetch: fetchMock,
      now: new Date(firstNow.getTime() + 24 * 60 * 60 * 1000),
    };
    await reportDroppedVmAlerts(
      [alertInput("vm-create-failure-spike"), alertInput("vm-stuck-provisioning"), alertInput("vm-create-failure-spike")],
      firstOptions,
    );
    await reportDroppedVmAlerts(
      [alertInput("vm-create-failure-spike"), alertInput("vm-stuck-provisioning")],
      secondOptions,
    );
    await reportDroppedVmAlerts([alertInput("vm-create-failure-spike")], nextDayOptions);

    const idsFor = (key: string) => captures
      .filter((capture) => capture.properties.alert_key === key)
      .map((capture) => capture.properties.$insert_id);
    const createFailureIds = idsFor("vm-create-failure-spike");
    const stuckIds = idsFor("vm-stuck-provisioning");
    expect(createFailureIds).toHaveLength(3);
    expect(stuckIds).toHaveLength(2);
    expect(createFailureIds[0]).toBe(createFailureIds[1]);
    expect(createFailureIds[1]).not.toBe(createFailureIds[2]);
    expect(stuckIds[0]).toBe(stuckIds[1]);
    expect(createFailureIds[0]).not.toBe(stuckIds[0]);
    expect(fetchMock).toHaveBeenCalledTimes(5);
  });

  test("dropped alerts stay quiet outside production", async () => {
    const fetchMock = mock(async () => new Response("ok")) as unknown as typeof fetch;

    await reportDroppedVmAlerts(
      [{ key: "k", title: "t", body: "b", severity: "warning" }],
      { env: {}, fetch: fetchMock },
    );

    expect(fetchMock).not.toHaveBeenCalled();
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
