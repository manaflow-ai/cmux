import { afterAll, beforeEach, describe, expect, mock, spyOn, test } from "bun:test";
import type { Event } from "@sentry/nextjs";
import { context as otelContext, SpanStatusCode, trace } from "@opentelemetry/api";
import { AsyncLocalStorageContextManager } from "@opentelemetry/context-async-hooks";
import {
  AlwaysOnSampler,
  BasicTracerProvider,
  InMemorySpanExporter,
  SimpleSpanProcessor,
} from "@opentelemetry/sdk-trace-base";

import vercelConfig from "../vercel.json";

// Reporting helpers read SENTRY_DSN; set it before any of them load.
process.env.SENTRY_DSN = "https://public@o0.ingest.sentry.io/0";
process.env.CRON_SECRET = "cron-secret";

type CapturedEvent = {
  readonly error: unknown;
  readonly tags: Record<string, string>;
  readonly contexts: Record<string, unknown>;
  readonly level?: string;
};
type CapturedCheckIn = {
  readonly checkIn: { monitorSlug: string; status: string; checkInId?: string; duration?: number };
  readonly config: { schedule: { value: string }; failureIssueThreshold?: number } | undefined;
};

const events: CapturedEvent[] = [];
const checkIns: CapturedCheckIn[] = [];
let flushes = 0;

mock.module("@sentry/nextjs", () => ({
  captureCheckIn: (checkIn: CapturedCheckIn["checkIn"], config: CapturedCheckIn["config"]) => {
    checkIns.push({ checkIn, config });
    return `check-in-${checkIns.length}`;
  },
  captureException: (error: unknown, hint?: { tags?: Record<string, string> }) => {
    events.push({ error, tags: { ...scope.tags, ...hint?.tags }, contexts: { ...scope.contexts }, level: scope.level });
    return "event-id";
  },
  withScope: (callback: (value: typeof scopeApi) => void) => {
    scope = freshScope();
    try {
      callback(scopeApi);
    } finally {
      scope = freshScope();
    }
  },
  flush: async () => {
    flushes += 1;
    return true;
  },
}));

function freshScope() {
  return { tags: {} as Record<string, string>, contexts: {} as Record<string, unknown>, level: undefined as string | undefined };
}
let scope = freshScope();
const scopeApi = {
  setLevel: (level: string) => { scope.level = level; },
  setContext: (key: string, value: unknown) => { scope.contexts[key] = value; },
  setTags: (tags: Record<string, string>) => { Object.assign(scope.tags, tags); },
  setFingerprint: () => {},
};

const workflowsModule = await import("../services/vms/workflows");
let workflowOutcome: () => Promise<unknown> = async () => ({});
mock.module("../services/vms/workflows", () => ({
  ...workflowsModule,
  runVmWorkflow: async () => workflowOutcome(),
}));

const retentionModule = await import("../services/apns/deviceRevocationRetention");
let pruneOutcome: () => Promise<number> = async () => 0;
mock.module("../services/apns/deviceRevocationRetention", () => ({
  ...retentionModule,
  pruneExpiredDeviceTokenRevocations: async () => pruneOutcome(),
}));

const diagnosticsModule = await import("../services/observability/cloudTelemetryDelivery");
let diagnosticsOutcome: () => Promise<Awaited<ReturnType<typeof diagnosticsModule.maintainCloudDiagnostics>>> =
  async () => ({ configured: true, delivered: 0 } as never);
mock.module("../services/observability/cloudTelemetryDelivery", () => ({
  ...diagnosticsModule,
  maintainCloudDiagnostics: async () => diagnosticsOutcome(),
}));

const { shouldSendSentryEvent } = await import("../services/sentry");
const { captureAscError } = await import("../services/errors");
const { reportError } = await import("../services/observability/report");
const { resetCronFailureReportsForTesting } = await import("../services/observability/cronMonitor");
const { withApiRouteSpan } = await import("../services/telemetry");
const vmReaper = await import("../app/api/cron/vm-reaper/route");
const vmRuntimeLimits = await import("../app/api/cron/vm-runtime-limits/route");
const pushTokenRevocations = await import("../app/api/cron/push-token-revocations/route");
const cloudDiagnostics = await import("../app/api/cron/cloud-diagnostics/route");

function cronRequest(path: string, authorization = "Bearer cron-secret"): Request {
  return new Request(`https://cmux.test/api/cron/${path}`, { headers: { authorization } });
}

function scheduleFor(cron: string): string | undefined {
  return vercelConfig.crons.find((entry) => entry.path === `/api/cron/${cron}`)?.schedule;
}

/** Sentry sends from a deferred task outside a request; wait for it. */
async function eventsSettled(count: number): Promise<void> {
  const deadline = performance.now() + 1_000;
  while (events.length < count && performance.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
  expect(events.length).toBe(count);
}

/** What the shared project's beforeSend sees for a captured event. */
function asSentryEvent(captured: CapturedEvent): Event {
  return { tags: captured.tags, contexts: captured.contexts as Event["contexts"] };
}

beforeEach(() => {
  events.length = 0;
  checkIns.length = 0;
  flushes = 0;
  resetCronFailureReportsForTesting();
});

describe("deliberate error reports reach Sentry", () => {
  test("App Store Connect captures pass the gate and flush", async () => {
    captureAscError(new Error("asc 500"), { operation: "list_builds" });
    await eventsSettled(1);
    expect(events[0]!.tags.subsystem).toBe("app-store-connect");
    expect(shouldSendSentryEvent(asSentryEvent(events[0]!))).toBe(true);
    expect(flushes).toBeGreaterThan(0);
  });

  test("reportError without a subsystem still passes and is tagged when the context names one", async () => {
    reportError(new Error("teams invite failed"), { subsystem: "teams", operation: "invite" });
    reportError(new Error("unnamed"), { operation: "x" });
    await eventsSettled(2);
    expect(events[0]!.tags.subsystem).toBe("teams");
    expect(events[1]!.tags.subsystem).toBeUndefined();
    for (const event of events) expect(shouldSendSentryEvent(asSentryEvent(event))).toBe(true);
  });

  test("raw unhandled request errors stay out of the shared project", () => {
    expect(shouldSendSentryEvent({
      request: { url: "https://cmux.com/api/teams" },
      exception: { values: [{ type: "TypeError", value: "boom" }] },
    })).toBe(false);
    expect(shouldSendSentryEvent({ tags: { subsystem: " " } })).toBe(false);
  });
});

describe("route span records a caught error behind a 5xx", () => {
  const exporter = new InMemorySpanExporter();
  trace.disable();
  otelContext.disable();
  const provider = new BasicTracerProvider({
    sampler: new AlwaysOnSampler(),
    spanProcessors: [new SimpleSpanProcessor(exporter)],
  });
  trace.setGlobalTracerProvider(provider);
  otelContext.setGlobalContextManager(new AsyncLocalStorageContextManager().enable());

  afterAll(async () => {
    await provider.shutdown();
    trace.disable();
    otelContext.disable();
  });

  async function route(handler: () => Promise<Response>) {
    exporter.reset();
    await withApiRouteSpan(new Request("https://cmux.com/api/teams", { method: "POST" }), "/api/teams", {}, handler);
    const spans = exporter.getFinishedSpans();
    expect(spans.length).toBe(1);
    return spans[0]!;
  }

  test("a reported error answered with 500 is the span's exception", async () => {
    const span = await route(async () => {
      try {
        throw new Error("database unavailable");
      } catch (error) {
        reportError(error, { subsystem: "teams" });
        return Response.json({ error: "internal" }, { status: 500 });
      }
    });
    expect(span.status.code).toBe(SpanStatusCode.ERROR);
    expect(span.status.message).toBe("database unavailable");
    expect(span.events.map((event) => event.name)).toContain("exception");
  });

  test("an unreported 5xx keeps the status and names the VM error code", async () => {
    const span = await route(async () =>
      new Response("{}", { status: 503, headers: { "x-cmux-vm-error": "vm_create_failed" } }));
    expect(span.status).toEqual({ code: SpanStatusCode.ERROR, message: "HTTP 503 vm_create_failed" });
    expect(span.events).toEqual([]);
  });

  test("a reported error the handler recovers from does not fail the span", async () => {
    const span = await route(async () => {
      captureAscError(new Error("asc flake"));
      return Response.json({ ok: true });
    });
    expect(span.status.code).toBe(SpanStatusCode.UNSET);
    expect(span.events).toEqual([]);
  });
});

describe("cron routes report failures and check in", () => {
  test("an unauthorized probe never checks in", async () => {
    expect((await vmReaper.GET(cronRequest("vm-reaper", "Bearer wrong"))).status).toBe(401);
    expect(checkIns).toEqual([]);
  });

  test("a failed reaper run reports once per window and checks in error on the vercel.json schedule", async () => {
    workflowOutcome = async () => { throw new Error("provider down"); };
    expect((await vmReaper.GET(cronRequest("vm-reaper"))).status).toBe(500);
    expect((await vmReaper.GET(cronRequest("vm-reaper"))).status).toBe(500);

    expect(checkIns.map((entry) => [entry.checkIn.monitorSlug, entry.checkIn.status])).toEqual([
      ["vm-reaper", "in_progress"],
      ["vm-reaper", "error"],
      ["vm-reaper", "in_progress"],
      ["vm-reaper", "error"],
    ]);
    expect(checkIns[1]!.checkIn.checkInId).toBe("check-in-1");
    expect(checkIns[0]!.config?.schedule.value).toBe(scheduleFor("vm-reaper")!);

    await eventsSettled(1);
    const event = events[0]!;
    expect((event.error as Error).message).toBe("provider down");
    expect(event.tags).toMatchObject({ subsystem: "cron", cron: "vm-reaper" });
    expect(shouldSendSentryEvent(asSentryEvent(event))).toBe(true);
  });

  test("partial runtime-limit enforcement reports and fails the check-in", async () => {
    workflowOutcome = async () => ({ checked: 3, paused: 1, errors: 1 });
    expect((await vmRuntimeLimits.GET(cronRequest("vm-runtime-limits"))).status).toBe(503);
    expect(checkIns.at(-1)!.checkIn.status).toBe("error");
    expect(checkIns[0]!.config?.schedule.value).toBe(scheduleFor("vm-runtime-limits")!);
    // A minute job needs consecutive failures before Sentry opens an issue.
    expect(checkIns[0]!.config?.failureIssueThreshold).toBe(3);
    await eventsSettled(1);
    expect(events[0]!.tags["cron.stage"]).toBe("partial");
  });

  test("a successful run checks in ok without an event", async () => {
    pruneOutcome = async () => 4;
    const response = await pushTokenRevocations.GET(cronRequest("push-token-revocations"));
    expect(await response.json()).toEqual({ ok: true, deleted: 4 });
    expect(checkIns.map((entry) => entry.checkIn.status)).toEqual(["in_progress", "ok"]);
    expect(checkIns[0]!.config?.schedule.value).toBe(scheduleFor("push-token-revocations")!);
    expect(events).toEqual([]);
  });

  test("an intentionally unconfigured diagnostics job answers 503 but keeps its monitor healthy", async () => {
    diagnosticsOutcome = async () => ({ configured: false, delivered: 0 } as never);
    // reportError logs synchronously before its deferred Sentry send, so an
    // absent log line proves no report was made.
    const reportLogs: unknown[] = [];
    const errorSpy = spyOn(console, "error").mockImplementation((...args: unknown[]) => { reportLogs.push(args[0]); });
    const warnSpy = spyOn(console, "warn").mockImplementation((...args: unknown[]) => { reportLogs.push(args[0]); });
    try {
      const response = await cloudDiagnostics.GET(cronRequest("cloud-diagnostics"));
      expect(response.status).toBe(503);
    } finally {
      errorSpy.mockRestore();
      warnSpy.mockRestore();
    }
    expect(checkIns.map((entry) => entry.checkIn.status)).toEqual(["in_progress", "ok"]);
    expect(reportLogs).not.toContain("cmux.observability.error");
    expect(reportLogs).toContain("cmux.cron.cloud_diagnostics.unconfigured");
    expect(events).toEqual([]);
  });

  test("a thrown diagnostics run answers 500 and reports instead of escaping as a raw request error", async () => {
    diagnosticsOutcome = async () => { throw new Error("db timeout"); };
    const response = await cloudDiagnostics.GET(cronRequest("cloud-diagnostics"));
    expect(response.status).toBe(500);
    expect(checkIns.map((entry) => entry.checkIn.status)).toEqual(["in_progress", "error"]);
    await eventsSettled(1);
    expect(events[0]!.tags.cron).toBe("cloud-diagnostics");
  });
});
