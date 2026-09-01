import { afterEach, describe, expect, mock, spyOn, test } from "bun:test";

import {
  VERBOSE_DIAGNOSTICS_METADATA_KEY,
  metadataApplyingVerboseDiagnostics,
  setVerboseDiagnostics,
  verboseDiagnosticsEnabled,
} from "../services/account/verboseDiagnostics";
import {
  VERBOSE_DIAGNOSTICS_LOG_MARKER,
  completeVerboseDiagnosticsRequest,
  recordVerboseDiagnosticsRequest,
} from "../services/observability/verboseDiagnostics";
import { withApiRouteSpan } from "../services/telemetry";

describe("verboseDiagnosticsEnabled", () => {
  test("only the literal boolean true enables the flag", () => {
    expect(verboseDiagnosticsEnabled({ cmuxVerboseDiagnostics: true })).toBe(true);
    expect(verboseDiagnosticsEnabled({ cmuxVerboseDiagnostics: false })).toBe(false);
    expect(verboseDiagnosticsEnabled(undefined)).toBe(false);
    expect(verboseDiagnosticsEnabled(null)).toBe(false);
    expect(verboseDiagnosticsEnabled({})).toBe(false);
    expect(verboseDiagnosticsEnabled({ cmuxPlan: "pro" })).toBe(false);
    // Fail closed on every non-boolean shape a bad write could produce.
    expect(verboseDiagnosticsEnabled({ cmuxVerboseDiagnostics: "true" })).toBe(false);
    expect(verboseDiagnosticsEnabled({ cmuxVerboseDiagnostics: 1 })).toBe(false);
    expect(verboseDiagnosticsEnabled({ cmuxVerboseDiagnostics: { enabled: true } })).toBe(false);
    expect(verboseDiagnosticsEnabled([true])).toBe(false);
    expect(verboseDiagnosticsEnabled("cmuxVerboseDiagnostics")).toBe(false);
  });
});

describe("metadataApplyingVerboseDiagnostics", () => {
  test("preserves every other metadata key in both directions", () => {
    const existing = {
      cmuxPlan: "pro",
      cmuxVmPlan: "vm-pro",
      cmuxReviewDemoContent: true,
    };
    const enabled = metadataApplyingVerboseDiagnostics(existing, true);
    expect(enabled).toEqual({
      ...existing,
      [VERBOSE_DIAGNOSTICS_METADATA_KEY]: true,
    });
    const disabled = metadataApplyingVerboseDiagnostics(enabled, false);
    expect(disabled).toEqual(existing);
  });

  test("normalizes malformed metadata to a fresh object", () => {
    expect(metadataApplyingVerboseDiagnostics(null, true)).toEqual({
      [VERBOSE_DIAGNOSTICS_METADATA_KEY]: true,
    });
    expect(metadataApplyingVerboseDiagnostics(["x"], false)).toEqual({});
  });
});

describe("setVerboseDiagnostics", () => {
  test("writes only on a state change and preserves other keys", async () => {
    const update = mock(async (_options: { clientReadOnlyMetadata: unknown }) => ({}));
    const user = {
      clientReadOnlyMetadata: { cmuxPlan: "pro" },
      update,
    };

    const after = await setVerboseDiagnostics(user, true);
    expect(after).toEqual({ cmuxPlan: "pro", [VERBOSE_DIAGNOSTICS_METADATA_KEY]: true });
    expect(update).toHaveBeenCalledTimes(1);
    expect(update.mock.calls[0]?.[0]?.clientReadOnlyMetadata).toEqual(after);

    // Same requested state again: no second write.
    const flaggedUser = { clientReadOnlyMetadata: after, update };
    await setVerboseDiagnostics(flaggedUser, true);
    expect(update).toHaveBeenCalledTimes(1);

    await setVerboseDiagnostics(flaggedUser, false);
    expect(update).toHaveBeenCalledTimes(2);
    expect(update.mock.calls[1]?.[0]?.clientReadOnlyMetadata).toEqual({ cmuxPlan: "pro" });
  });
});

describe("request logging", () => {
  const marker = VERBOSE_DIAGNOSTICS_LOG_MARKER;

  function markerLines(spy: ReturnType<typeof spyOn>): string[] {
    return spy.mock.calls
      .map((call) => String(call[0]))
      .filter((line) => line.startsWith(marker));
  }

  afterEach(() => {
    mock.restore();
  });

  test("marker line is emitted only for a flagged user", () => {
    const log = spyOn(console, "log").mockImplementation(() => {});
    const flagged = new Request("https://cmux.example/api/devices?after=1", {
      method: "GET",
      headers: { "user-agent": "cmux-ios/1.0" },
    });
    const unflagged = new Request("https://cmux.example/api/devices", { method: "GET" });

    recordVerboseDiagnosticsRequest(unflagged, { id: "user-plain" });
    recordVerboseDiagnosticsRequest(unflagged, {
      id: "user-plain",
      verboseDiagnostics: false,
    });
    expect(markerLines(log)).toHaveLength(0);

    recordVerboseDiagnosticsRequest(flagged, {
      id: "user-flagged",
      verboseDiagnostics: true,
    });
    const lines = markerLines(log);
    expect(lines).toHaveLength(1);
    const payload = JSON.parse(lines[0]!.slice(marker.length + 1)) as Record<string, unknown>;
    expect(payload.kind).toBe("request");
    expect(payload.method).toBe("GET");
    expect(payload.path).toBe("/api/devices");
    expect(payload.userId).toBe("user-flagged");
    expect(payload.userAgent).toBe("cmux-ios/1.0");
    // Query parameter names only, never values.
    expect(payload.queryKeys).toBe("after");
    expect(JSON.stringify(payload)).not.toContain("after=1");
  });

  test("recording the same request twice emits one line", () => {
    const log = spyOn(console, "log").mockImplementation(() => {});
    const request = new Request("https://cmux.example/api/devices", { method: "GET" });
    recordVerboseDiagnosticsRequest(request, { id: "u", verboseDiagnostics: true });
    recordVerboseDiagnosticsRequest(request, { id: "u", verboseDiagnostics: true });
    expect(markerLines(log)).toHaveLength(1);
  });

  test("completion emits status and duration only for tracked requests", () => {
    const log = spyOn(console, "log").mockImplementation(() => {});
    const untracked = new Request("https://cmux.example/api/devices", { method: "GET" });
    completeVerboseDiagnosticsRequest(untracked, { route: "/api/devices", status: 200 });
    expect(markerLines(log)).toHaveLength(0);

    const tracked = new Request("https://cmux.example/api/devices", { method: "PUT" });
    recordVerboseDiagnosticsRequest(tracked, { id: "user-flagged", verboseDiagnostics: true });
    completeVerboseDiagnosticsRequest(tracked, { route: "/api/devices", status: 207 });
    // A second completion (span wrapper + fallback) never double-logs.
    completeVerboseDiagnosticsRequest(tracked, { route: "/api/devices", status: 207 });

    const lines = markerLines(log);
    expect(lines).toHaveLength(2);
    const payload = JSON.parse(lines[1]!.slice(marker.length + 1)) as Record<string, unknown>;
    expect(payload.kind).toBe("response");
    expect(payload.route).toBe("/api/devices");
    expect(payload.status).toBe(207);
    expect(payload.userId).toBe("user-flagged");
    expect(typeof payload.durationMs).toBe("number");
  });

  test("withApiRouteSpan completes a flagged request with the response status", async () => {
    const log = spyOn(console, "log").mockImplementation(() => {});
    const request = new Request("https://cmux.example/api/diagnostics/ingest", {
      method: "POST",
    });
    const response = await withApiRouteSpan(
      request,
      "/api/diagnostics/ingest",
      {},
      async () => {
        recordVerboseDiagnosticsRequest(request, {
          id: "user-flagged",
          verboseDiagnostics: true,
        });
        return new Response(null, { status: 202 });
      },
    );
    expect(response.status).toBe(202);
    const lines = markerLines(log);
    expect(lines).toHaveLength(2);
    const payload = JSON.parse(lines[1]!.slice(marker.length + 1)) as Record<string, unknown>;
    expect(payload.kind).toBe("response");
    expect(payload.status).toBe(202);
  });

  test("withApiRouteSpan reports handler errors for a flagged request", async () => {
    const log = spyOn(console, "log").mockImplementation(() => {});
    const request = new Request("https://cmux.example/api/devices", { method: "GET" });
    await expect(
      withApiRouteSpan(request, "/api/devices", {}, async () => {
        recordVerboseDiagnosticsRequest(request, {
          id: "user-flagged",
          verboseDiagnostics: true,
        });
        throw new Error("boom");
      }),
    ).rejects.toThrow("boom");
    const lines = markerLines(log);
    expect(lines).toHaveLength(2);
    const payload = JSON.parse(lines[1]!.slice(marker.length + 1)) as Record<string, unknown>;
    expect(payload.kind).toBe("response");
    expect(payload.errorName).toBe("Error");
    expect(payload.errorMessage).toBe("boom");
    expect(payload.status).toBeUndefined();
  });
});
