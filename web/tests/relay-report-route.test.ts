import { describe, expect, test } from "bun:test";
import { randomBytes } from "node:crypto";

import {
  handleRelayReportRequest,
  type RelayReportDeps,
} from "../app/api/relay/report/route";
import { relayAllowSignature } from "../services/relay/allow";
import {
  RELAY_REPORT_MAX_CONCURRENT,
  RELAY_REPORT_MAX_FUTURE_SKEW_MS,
  RELAY_REPORT_SIGNATURE_HEADER,
  RelayReportSaturatedError,
  parseRelayAttachReport,
  publishableRelayURLForHostname,
  withRelayReportSlot,
  type RelayAttachReport,
} from "../services/relay/report";

// Pure route tests: deps injection only, nothing leaks into the shared
// bun-test module registry, no database.
const SECRET = randomBytes(32);
const SECRET_B64 = SECRET.toString("base64");
const ENDPOINT_ID = "0123456789abcdef".repeat(4);
const NOW = new Date("2026-08-25T12:00:00.000Z");
const MANAGED_HOSTNAME = "usc1.relay.cmux.dev";
const MANAGED_URL = "https://usc1.relay.cmux.dev/";

function deps(overrides: Partial<RelayReportDeps> = {}): RelayReportDeps {
  return {
    secretBase64: () => SECRET_B64,
    apply: async () => "applied",
    now: () => NOW,
    ...overrides,
  };
}

function reportBody(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    endpointId: ENDPOINT_ID,
    event: "attach",
    relayId: MANAGED_HOSTNAME,
    ts: NOW.getTime(),
    ...overrides,
  };
}

/** The exact shape the cmux-relay Reporter sends: JSON body, signature header. */
function signedRequest(body: unknown, signature?: string): Request {
  const text = JSON.stringify(body);
  return new Request("https://cmux.dev/api/relay/report", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      [RELAY_REPORT_SIGNATURE_HEADER]:
        signature ?? relayAllowSignature(SECRET, Buffer.from(text, "utf8")),
    },
    body: text,
  });
}

describe("POST /api/relay/report", () => {
  test("applies a signed attach report, uncacheable", async () => {
    const observed: RelayAttachReport[] = [];
    const response = await handleRelayReportRequest(
      signedRequest(reportBody()),
      deps({
        apply: async (report) => {
          observed.push(report);
          return "applied";
        },
      }),
    );
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ applied: true });
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(observed).toEqual([{
      endpointId: ENDPOINT_ID,
      event: "attach",
      relayId: MANAGED_HOSTNAME,
      reportedAt: NOW,
    }]);
  });

  test("applies a signed detach report", async () => {
    const observed: RelayAttachReport[] = [];
    const response = await handleRelayReportRequest(
      signedRequest(reportBody({ event: "detach" })),
      deps({
        apply: async (report) => {
          observed.push(report);
          return "applied";
        },
      }),
    );
    expect(response.status).toBe(200);
    expect(observed[0]?.event).toBe("detach");
  });

  test("rejects a missing signature without touching the registry", async () => {
    let applications = 0;
    const text = JSON.stringify(reportBody());
    const response = await handleRelayReportRequest(
      new Request("https://cmux.dev/api/relay/report", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: text,
      }),
      deps({
        apply: async () => {
          applications += 1;
          return "applied";
        },
      }),
    );
    expect(response.status).toBe(401);
    expect(await response.json()).toEqual({ error: "invalid_relay_report_signature" });
    expect(applications).toBe(0);
  });

  test("rejects a signature over different body bytes", async () => {
    const response = await handleRelayReportRequest(
      signedRequest(
        reportBody(),
        relayAllowSignature(SECRET, Buffer.from("{}", "utf8")),
      ),
      deps(),
    );
    expect(response.status).toBe(401);
  });

  test("rejects a signature minted with the wrong secret", async () => {
    const text = JSON.stringify(reportBody());
    const response = await handleRelayReportRequest(
      signedRequest(
        reportBody(),
        relayAllowSignature(randomBytes(32), Buffer.from(text, "utf8")),
      ),
      deps(),
    );
    expect(response.status).toBe(401);
  });

  test("answers 503 when the shared secret is not configured", async () => {
    const response = await handleRelayReportRequest(
      signedRequest(reportBody()),
      deps({ secretBase64: () => undefined }),
    );
    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ error: "relay_report_not_configured" });
  });

  test("rejects a signed empty body", async () => {
    const response = await handleRelayReportRequest(
      new Request("https://cmux.dev/api/relay/report", {
        method: "POST",
        headers: {
          [RELAY_REPORT_SIGNATURE_HEADER]:
            relayAllowSignature(SECRET, new Uint8Array()),
        },
      }),
      deps(),
    );
    expect(response.status).toBe(400);
    expect(await response.json()).toEqual({ error: "missing_report_body" });
  });

  test("rejects signed malformed JSON", async () => {
    const text = "{not json";
    const response = await handleRelayReportRequest(
      new Request("https://cmux.dev/api/relay/report", {
        method: "POST",
        headers: {
          [RELAY_REPORT_SIGNATURE_HEADER]:
            relayAllowSignature(SECRET, Buffer.from(text, "utf8")),
        },
        body: text,
      }),
      deps(),
    );
    expect(response.status).toBe(400);
    expect(await response.json()).toEqual({ error: "invalid_json" });
  });

  test("rejects malformed reports with the specific failure code", async () => {
    const cases: ReadonlyArray<readonly [unknown, string]> = [
      [reportBody({ endpointId: "not-hex" }), "invalid_endpoint_id"],
      [reportBody({ endpointId: ENDPOINT_ID.slice(1) }), "invalid_endpoint_id"],
      [reportBody({ event: "connected" }), "invalid_report_event"],
      [reportBody({ relayId: "" }), "invalid_relay_id"],
      [reportBody({ relayId: "bad_host!" }), "invalid_relay_id"],
      [reportBody({ relayId: `${"a".repeat(64)}.example` }), "invalid_relay_id"],
      [reportBody({ ts: "123" }), "invalid_report_time"],
      [reportBody({ ts: 0 }), "invalid_report_time"],
      [reportBody({ ts: 1.5 }), "invalid_report_time"],
      [reportBody({ extra: true }), "invalid_report_body"],
      [[reportBody()], "invalid_report_body"],
    ];
    for (const [body, error] of cases) {
      const response = await handleRelayReportRequest(signedRequest(body), deps());
      expect(response.status).toBe(400);
      expect(await response.json()).toEqual({ error });
    }
  });

  test("rejects an event timestamp too far in the future", async () => {
    const response = await handleRelayReportRequest(
      signedRequest(reportBody({
        ts: NOW.getTime() + RELAY_REPORT_MAX_FUTURE_SKEW_MS + 1,
      })),
      deps(),
    );
    expect(response.status).toBe(400);
    expect(await response.json()).toEqual({ error: "invalid_report_time" });
  });

  test("rejects an oversized declared body without reading it", async () => {
    const response = await handleRelayReportRequest(
      new Request("https://cmux.dev/api/relay/report", {
        method: "POST",
        headers: {
          "content-length": String(1024 * 1024),
          [RELAY_REPORT_SIGNATURE_HEADER]:
            relayAllowSignature(SECRET, new Uint8Array()),
        },
        body: new ReadableStream<Uint8Array>({
          pull(controller) {
            controller.enqueue(new Uint8Array(1024));
          },
        }),
      }),
      deps(),
    );
    expect(response.status).toBe(413);
  });

  test("rejects an oversized streamed body at the byte cap", async () => {
    const chunk = new Uint8Array(1024);
    let sent = 0;
    const response = await handleRelayReportRequest(
      new Request("https://cmux.dev/api/relay/report", {
        method: "POST",
        headers: {
          [RELAY_REPORT_SIGNATURE_HEADER]:
            relayAllowSignature(SECRET, new Uint8Array()),
        },
        body: new ReadableStream<Uint8Array>({
          pull(controller) {
            sent += 1;
            if (sent > 32) {
              controller.close();
              return;
            }
            controller.enqueue(chunk);
          },
        }),
      }),
      deps(),
    );
    expect(response.status).toBe(413);
  });

  test("times out a trickled body instead of waiting forever", async () => {
    const response = await handleRelayReportRequest(
      new Request("https://cmux.dev/api/relay/report", {
        method: "POST",
        headers: {
          [RELAY_REPORT_SIGNATURE_HEADER]:
            relayAllowSignature(SECRET, new Uint8Array()),
        },
        // A stream that never produces data and never closes.
        body: new ReadableStream<Uint8Array>({ pull: () => new Promise(() => {}) }),
      }),
      deps({ bodyReadTimeoutMs: 25 }),
    );
    expect(response.status).toBe(408);
  });

  test("answers 403 for a trusted-signature report about an untrusted relay", async () => {
    const response = await handleRelayReportRequest(
      signedRequest(reportBody()),
      deps({ apply: async () => "untrusted_relay" }),
    );
    expect(response.status).toBe(403);
    expect(await response.json()).toEqual({ error: "untrusted_relay" });
  });

  test("answers applied:false for stale or unknown reports without failing the relay", async () => {
    for (const outcome of ["superseded", "unknown_endpoint"] as const) {
      const response = await handleRelayReportRequest(
        signedRequest(reportBody()),
        deps({ apply: async () => outcome }),
      );
      expect(response.status).toBe(200);
      expect(await response.json()).toEqual({ applied: false, reason: outcome });
    }
  });

  test("bounds application latency and fails to 503 on expiry", async () => {
    const response = await handleRelayReportRequest(
      signedRequest(reportBody()),
      deps({
        apply: () => new Promise(() => {}),
        applyTimeoutMs: 25,
      }),
    );
    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ error: "relay_report_unavailable" });
  });

  test("answers 503 when report concurrency is saturated", async () => {
    const response = await handleRelayReportRequest(
      signedRequest(reportBody()),
      deps({
        apply: async () => {
          throw new RelayReportSaturatedError();
        },
      }),
    );
    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ error: "relay_report_saturated" });
  });
});

describe("relay report concurrency slots", () => {
  test("rejects work past the cap and recovers as slots settle", async () => {
    const releases: Array<() => void> = [];
    const held = Array.from(
      { length: RELAY_REPORT_MAX_CONCURRENT },
      () => withRelayReportSlot(
        () => new Promise<void>((resolve) => releases.push(resolve)),
      ),
    );
    await Promise.resolve();
    await expect(withRelayReportSlot(async () => "over")).rejects.toThrow(
      RelayReportSaturatedError,
    );
    for (const release of releases) release();
    await Promise.all(held);
    expect(await withRelayReportSlot(async () => "recovered")).toBe("recovered");
  });
});

describe("relay report parsing and trust mapping", () => {
  test("normalizes case and preserves millisecond timestamps", () => {
    const parsed = parseRelayAttachReport({
      endpointId: ENDPOINT_ID.toUpperCase(),
      event: "attach",
      relayId: MANAGED_HOSTNAME.toUpperCase(),
      ts: 1_756_100_000_123,
    }, new Date(1_756_100_000_500));
    expect(parsed).toEqual({
      ok: true,
      report: {
        endpointId: ENDPOINT_ID,
        event: "attach",
        relayId: MANAGED_HOSTNAME,
        reportedAt: new Date(1_756_100_000_123),
      },
    });
  });

  test("maps a managed hostname to its exact catalog URL", () => {
    expect(publishableRelayURLForHostname(MANAGED_HOSTNAME, [])).toBe(MANAGED_URL);
  });

  test("maps a saved custom hostname to the saved URL verbatim", () => {
    expect(publishableRelayURLForHostname(
      "relay.corp.example",
      ["https://relay.corp.example:8443/"],
    )).toBe("https://relay.corp.example:8443/");
  });

  test("refuses hostnames outside the catalog and the saved set", () => {
    expect(publishableRelayURLForHostname("cmux-relay-dev", [])).toBeNull();
    expect(publishableRelayURLForHostname(
      "evil.example",
      ["https://relay.corp.example:8443/"],
    )).toBeNull();
  });

  test("the catalog wins over a saved custom relay with the same hostname", () => {
    expect(publishableRelayURLForHostname(
      MANAGED_HOSTNAME,
      [`https://${MANAGED_HOSTNAME}:8443/`],
    )).toBe(MANAGED_URL);
  });
});
