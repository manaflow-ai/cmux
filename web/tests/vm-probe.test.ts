import { describe, expect, test } from "bun:test";
import { VmCreateCreditsInsufficientError, VmProviderOperationError } from "../services/vms/errors";
import {
  getVmProbeFreshness,
  runVmProbe,
  type VmProbeAlertInput,
  type VmProbePersistedState,
} from "../services/observability/vmProbe";
import type { ExecResult, ProviderId } from "../services/vms/drivers";
import type { VmEntry } from "../services/vms/workflows";

const baseEnv = {
  CMUX_VM_PROBE_USER_ID: "probe-user",
  CMUX_VM_PROBE_TEAM_ID: "probe-team",
  CMUX_VM_PROBE_PLAN_ID: "free",
  CMUX_VM_PROBE_PROVIDER: "e2b",
  CMUX_VM_PROBE_IMAGE: "cmuxd-ws:tooling-20260509f",
  CMUX_VM_PROBE_CREATE_TIMEOUT_MS: "120000",
  CMUX_VM_PROBE_STATUS_TIMEOUT_MS: "60000",
  CMUX_VM_PROBE_EXEC_TIMEOUT_MS: "30000",
  CMUX_VM_PROBE_DESTROY_TIMEOUT_MS: "60000",
  CMUX_VM_PROBE_STATUS_POLL_MS: "1000",
};

describe("Cloud VM synthetic probe", () => {
  test("happy path updates state without alerting", async () => {
    const harness = makeHarness();
    const summary = await harness.run();

    expect(summary).toMatchObject({ status: "success", vmId: "provider-probe-1" });
    if ("skipped" in summary) throw new Error("unexpected skip");
    expect(summary.steps.map((step) => [step.step, step.outcome])).toEqual([
      ["create", "ok"],
      ["status", "ok"],
      ["exec", "ok"],
      ["destroy", "ok"],
    ]);
    expect(harness.alerts).toEqual([]);
    expect(harness.store.state?.lastSuccessAt?.toISOString()).toBe(summary.finishedAt);
    expect(harness.store.state?.consecutiveFailures).toBe(0);
  });

  test("exec failure alerts with the exec step and still destroys the VM", async () => {
    const harness = makeHarness({
      exec: async () => {
        throw new VmProviderOperationError({
          provider: "e2b",
          operation: "exec",
          cause: new Error("exec gateway down"),
        });
      },
    });
    const summary = await harness.run();

    if ("skipped" in summary) throw new Error("unexpected skip");
    expect(summary.status).toBe("failure");
    expect(harness.destroyed).toEqual(["provider-probe-1"]);
    expect(harness.alerts).toHaveLength(1);
    expect(harness.alerts[0]).toMatchObject({
      key: "vm-probe-step-failed",
      severity: "critical",
    });
    expect(harness.alerts[0]?.body).toContain("Step: exec.");
    expect(harness.alerts[0]?.body).toContain("Code: vm_cloud_service_unavailable.");
  });

  test("exec failure redacts provider secrets from alerts and persisted state", async () => {
    const harness = makeHarness({
      exec: async () => {
        throw new VmProviderOperationError({
          provider: "e2b",
          operation: "exec",
          cause: new Error("exec denied with Bearer srt_secret123token and api key sk-liveSecret123"),
        });
      },
    });
    const summary = await harness.run();

    if ("skipped" in summary) throw new Error("unexpected skip");
    expect(summary.status).toBe("failure");
    expect(harness.alerts).toHaveLength(1);
    const alertBody = harness.alerts[0]?.body ?? "";
    const persistedMessage = harness.store.state?.lastErrorMessage ?? "";

    expect(alertBody).toContain("Step: exec.");
    expect(alertBody).toContain("Code: vm_cloud_service_unavailable.");
    expect(alertBody).toContain("[redacted]");
    expect(alertBody).not.toContain("Bearer srt_secret123token");
    expect(alertBody).not.toContain("srt_secret123token");
    expect(alertBody).not.toContain("sk-liveSecret123");
    expect(harness.store.state?.lastErrorCode).toBe("vm_cloud_service_unavailable");
    expect(persistedMessage).toContain("[redacted]");
    expect(persistedMessage).not.toContain("Bearer srt_secret123token");
    expect(persistedMessage).not.toContain("srt_secret123token");
    expect(persistedMessage).not.toContain("sk-liveSecret123");
  });

  test("exec failure followed by destroy failure keeps the original outage as the persisted root cause", async () => {
    const harness = makeHarness({
      exec: async () => {
        throw new VmProviderOperationError({
          provider: "e2b",
          operation: "exec",
          cause: new Error("exec gateway down"),
        });
      },
      destroy: async () => {
        throw new VmProviderOperationError({
          provider: "e2b",
          operation: "destroy",
          cause: new Error("destroy also down"),
        });
      },
    });
    const summary = await harness.run();

    if ("skipped" in summary) throw new Error("unexpected skip");
    expect(summary.status).toBe("failure");
    expect(harness.alerts.map((alert) => alert.key)).toEqual([
      "vm-probe-destroy-failed",
      "vm-probe-step-failed",
    ]);
    expect(harness.alerts[1]?.body).toContain("Step: exec.");
    expect(harness.alerts[1]?.body).toContain("Code: vm_cloud_service_unavailable.");
    expect(harness.store.state?.lastErrorCode).toBe("vm_cloud_service_unavailable");
    expect(harness.store.state?.lastErrorMessage).toContain("exec gateway down");
  });

  test("create credits failure sends the distinct credits alert", async () => {
    const harness = makeHarness({
      create: async () => {
        throw new VmCreateCreditsInsufficientError({
          itemId: "credit-item",
          billingCustomerId: "probe-team",
          amount: 1,
        });
      },
    });
    const summary = await harness.run();

    if ("skipped" in summary) throw new Error("unexpected skip");
    expect(summary.status).toBe("failure");
    expect(harness.destroyed).toEqual([]);
    expect(harness.alerts.map((alert) => alert.key)).toEqual(["vm-probe-credits-exhausted"]);
    expect(harness.alerts[0]?.severity).toBe("warning");
    expect(harness.alerts[0]?.body).toContain("vm_create_credits_insufficient");
  });

  test("budget breach alerts even when the step succeeds", async () => {
    const harness = makeHarness({
      create: async (input) => {
        harness.clock.advance(121_000);
        return vmEntry({ providerVmId: "provider-probe-1", provider: input.provider });
      },
    });
    const summary = await harness.run();

    if ("skipped" in summary) throw new Error("unexpected skip");
    expect(summary.status).toBe("failure");
    expect(summary.steps[0]).toMatchObject({
      step: "create",
      outcome: "ok",
      budgetExceeded: true,
    });
    expect(harness.destroyed).toEqual(["provider-probe-1"]);
    expect(harness.alerts[0]).toMatchObject({
      key: "vm-probe-step-failed",
      severity: "critical",
    });
    expect(harness.alerts[0]?.body).toContain("vm_probe_budget_exceeded");
  });

  test("destroy failure sends a leak alert and records failure state", async () => {
    const harness = makeHarness({
      destroy: async () => {
        throw new VmProviderOperationError({
          provider: "e2b",
          operation: "destroy",
          cause: new Error("destroy failed"),
        });
      },
    });
    const summary = await harness.run();

    if ("skipped" in summary) throw new Error("unexpected skip");
    expect(summary.status).toBe("failure");
    expect(harness.alerts.map((alert) => alert.key)).toEqual(["vm-probe-destroy-failed"]);
    expect(harness.store.state?.consecutiveFailures).toBe(1);
    expect(harness.store.state?.lastErrorCode).toBe("vm_cloud_service_unavailable");
  });

  test("successful destroy budget breach sends a step alert", async () => {
    const harness = makeHarness({
      destroy: async () => {
        harness.clock.advance(61_000);
      },
    });
    const summary = await harness.run();

    if ("skipped" in summary) throw new Error("unexpected skip");
    expect(summary.status).toBe("failure");
    expect(summary.steps.find((step) => step.step === "destroy")).toMatchObject({
      outcome: "ok",
      budgetExceeded: true,
    });
    expect(harness.alerts.map((alert) => alert.key)).toEqual(["vm-probe-step-failed"]);
    expect(harness.alerts[0]?.body).toContain("Step: destroy.");
    expect(harness.alerts[0]?.body).toContain("vm_probe_budget_exceeded");
  });

  test("first success after failure sends one recovery alert", async () => {
    const previousFailure: VmProbePersistedState = {
      key: "default",
      lastRunAt: new Date("2026-07-05T10:00:00.000Z"),
      lastSuccessAt: null,
      consecutiveFailures: 2,
      lastErrorCode: "vm_cloud_service_unavailable",
      lastErrorMessage: "exec failed",
    };
    const harness = makeHarness({ initialState: previousFailure });

    const first = await harness.run();
    const second = await harness.run();

    if ("skipped" in first || "skipped" in second) throw new Error("unexpected skip");
    expect(first.status).toBe("success");
    expect(second.status).toBe("success");
    expect(harness.alerts.map((alert) => alert.key)).toEqual(["vm-probe-recovered"]);
    expect(harness.alerts[0]?.severity).toBe("warning");
  });

  test("success state write failure suppresses recovery until the state is persisted", async () => {
    const previousFailure: VmProbePersistedState = {
      key: "default",
      lastRunAt: new Date("2026-07-05T10:00:00.000Z"),
      lastSuccessAt: null,
      consecutiveFailures: 2,
      lastErrorCode: "vm_cloud_service_unavailable",
      lastErrorMessage: "exec failed",
    };
    const harness = makeHarness({ initialState: previousFailure, failRecordResult: true });

    const first = await harness.run();
    const second = await harness.run();

    if ("skipped" in first || "skipped" in second) throw new Error("unexpected skip");
    expect(first.status).toBe("success");
    expect(first.stateWriteError?.message).toBe("probe state write failed");
    expect(second.status).toBe("success");
    expect(harness.alerts.map((alert) => alert.key)).toEqual(["vm-probe-recovered"]);
    expect(harness.store.state?.consecutiveFailures).toBe(0);
  });

  test("unconfigured env skips without workflow calls or alerts", async () => {
    const harness = makeHarness({ env: {} });
    const summary = await harness.run();

    expect(summary).toEqual({ skipped: "probe_not_configured" });
    expect(harness.workflowCalls).toEqual([]);
    expect(harness.alerts).toEqual([]);
  });

  test("configuration failure alerts, records failure, and does not throw", async () => {
    const harness = makeHarness({
      env: {
        ...baseEnv,
        VERCEL_ENV: "production",
        CMUX_VM_PROBE_IMAGE: "missing-image",
      },
    });
    const summary = await harness.run();

    if ("skipped" in summary) throw new Error("unexpected skip");
    expect(summary.status).toBe("failure");
    expect(summary.provider).toBeNull();
    expect(summary.steps).toEqual([]);
    expect(harness.workflowCalls).toEqual([]);
    expect(harness.alerts).toHaveLength(1);
    expect(harness.alerts[0]).toMatchObject({
      key: "vm-probe-run-failed",
      severity: "critical",
    });
    expect(harness.alerts[0]?.body).toContain("Phase: config.");
    expect(harness.store.state?.consecutiveFailures).toBe(1);
    expect(harness.store.state?.lastErrorCode).toBe("vm_image_config");
  });

  test("create-disabled configuration skips without alerting or incrementing failures", async () => {
    const harness = makeHarness({
      env: {
        ...baseEnv,
        CMUX_VM_CREATE_ENABLED: "0",
      },
    });
    const summary = await harness.run();

    expect(summary).toEqual({
      skipped: "create_disabled",
      reason: "Cloud VM creation is disabled",
    });
    expect(harness.workflowCalls).toEqual([]);
    expect(harness.alerts).toEqual([]);
    expect(harness.store.state).toBeNull();
  });

  test("freshness reports stale versus fresh and leaks no details", async () => {
    const fresh = await getVmProbeFreshness({
      now: new Date("2026-07-05T12:30:00.000Z"),
      env: { CMUX_VM_PROBE_FRESHNESS_STALE_MS: "2700000" },
      store: {
        getState: async () => ({
          key: "default",
          lastRunAt: new Date("2026-07-05T12:00:00.000Z"),
          lastSuccessAt: new Date("2026-07-05T12:00:00.000Z"),
          consecutiveFailures: 7,
          lastErrorCode: "secret-code",
          lastErrorMessage: "secret-message",
        }),
      },
    });
    const stale = await getVmProbeFreshness({
      now: new Date("2026-07-05T13:00:01.000Z"),
      env: { CMUX_VM_PROBE_FRESHNESS_STALE_MS: "2700000" },
      store: {
        getState: async () => ({
          key: "default",
          lastRunAt: new Date("2026-07-05T12:00:00.000Z"),
          lastSuccessAt: new Date("2026-07-05T12:00:00.000Z"),
          consecutiveFailures: 7,
          lastErrorCode: "secret-code",
          lastErrorMessage: "secret-message",
        }),
      },
    });

    expect(fresh).toEqual({ lastSuccessAt: "2026-07-05T12:00:00.000Z", stale: false });
    expect(stale).toEqual({ lastSuccessAt: "2026-07-05T12:00:00.000Z", stale: true });
    expect(Object.keys(fresh).sort()).toEqual(["lastSuccessAt", "stale"]);
    expect(JSON.stringify(fresh)).not.toContain("secret");
  });
});

function makeHarness(overrides: {
  readonly env?: Record<string, string | undefined>;
  readonly initialState?: VmProbePersistedState | null;
  readonly failRecordResult?: boolean;
  readonly create?: (input: Parameters<typeof runVmProbe>[0] extends never ? never : {
    readonly provider: ProviderId;
  }) => Promise<VmEntry>;
  readonly get?: () => Promise<VmEntry>;
  readonly exec?: () => Promise<ExecResult>;
  readonly destroy?: () => Promise<void>;
} = {}) {
  const alerts: VmProbeAlertInput[] = [];
  const destroyed: string[] = [];
  const workflowCalls: string[] = [];
  const clock = fakeClock(new Date("2026-07-05T12:00:00.000Z"));
  const store = fakeStore(overrides.initialState ?? null, overrides.failRecordResult ?? false);
  const workflows = {
    create: async (input: { provider: ProviderId }) => {
      workflowCalls.push("create");
      return overrides.create
        ? overrides.create(input)
        : vmEntry({ providerVmId: "provider-probe-1", provider: input.provider });
    },
    get: async () => {
      workflowCalls.push("get");
      return overrides.get ? overrides.get() : vmEntry({ providerVmId: "provider-probe-1", status: "running" });
    },
    exec: async () => {
      workflowCalls.push("exec");
      return overrides.exec ? overrides.exec() : { exitCode: 0, stdout: "cmux-probe-ok\n", stderr: "" };
    },
    destroy: async (input: { providerVmId: string }) => {
      workflowCalls.push("destroy");
      if (overrides.destroy) return overrides.destroy();
      destroyed.push(input.providerVmId);
    },
  };
  return {
    alerts,
    destroyed,
    workflowCalls,
    clock,
    store,
    run: () =>
      runVmProbe({
        env: overrides.env ?? baseEnv,
        clock,
        store,
        workflows,
        sendAlert: async (input) => {
          alerts.push(input);
          return { sent: true, status: 200 };
        },
      }),
  };
}

function fakeClock(initial: Date) {
  let current = initial.getTime();
  return {
    now: () => new Date(current),
    delay: async (ms: number) => {
      current += ms;
    },
    advance: (ms: number) => {
      current += ms;
    },
  };
}

function fakeStore(initialState: VmProbePersistedState | null, failRecordResult: boolean) {
  const store = {
    state: initialState,
    failRecordResult,
    getState: async () => store.state,
    recordResult: async (input: {
      now: Date;
      success: boolean;
      errorCode: string | null;
      errorMessage: string | null;
      previousState: VmProbePersistedState | null;
    }) => {
      if (store.failRecordResult) {
        store.failRecordResult = false;
        throw new Error("probe state write failed");
      }
      const previous = input.previousState ?? store.state;
      const next: VmProbePersistedState = {
        key: "default",
        lastRunAt: input.now,
        lastSuccessAt: input.success ? input.now : previous?.lastSuccessAt ?? null,
        consecutiveFailures: input.success ? 0 : (previous?.consecutiveFailures ?? 0) + 1,
        lastErrorCode: input.success ? null : input.errorCode,
        lastErrorMessage: input.success ? null : input.errorMessage,
      };
      store.state = next;
      return next;
    },
    listStaleProbeVms: async () => [],
  };
  return store;
}

function vmEntry(input: {
  readonly providerVmId: string;
  readonly provider?: ProviderId;
  readonly status?: VmEntry["status"];
}): VmEntry {
  return {
    providerVmId: input.providerVmId,
    provider: input.provider ?? "e2b",
    image: "cmuxd-ws:tooling-20260509f",
    imageVersion: "e2b-tooling-20260509f",
    status: input.status ?? "running",
    createdAt: Date.parse("2026-07-05T12:00:00.000Z"),
  };
}
