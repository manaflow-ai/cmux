import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import postgres, { type Sql } from "postgres";
import { closeCloudDbForTests } from "../db/client";
import {
  FREE_INITIAL_CREATE_CREDITS_REASON,
  VmBillingGateway,
  noOpVmBillingGateway,
  type VmBillingGatewayShape,
} from "../services/vms/billingGateway";
import type { AttachEndpoint, SSHEndpoint, VMHandle } from "../services/vms/drivers";
import { VmProviderGateway, type VmProviderGatewayShape } from "../services/vms/providerGateway";
import {
  VmRepository,
  VmRepositoryLive,
  type CloudVmRow,
  type VmRepositoryShape,
} from "../services/vms/repository";
import {
  VmCreateCreditsInsufficientError,
  VmCreateInProgressError,
  VmDatabaseError,
  VmLimitExceededError,
  VmNotFoundError,
  VmProviderOperationError,
} from "../services/vms/errors";
import {
  createVm,
  destroyVm,
  execVm,
  openAttachEndpoint,
  openSshEndpoint,
} from "../services/vms/workflows";

const runDbTests = process.env.CMUX_DB_TEST === "1";
const dbTest = runDbTests ? test : test.skip;

let sql: Sql | null = null;

type RecordedUsageEvent = Parameters<VmRepositoryShape["recordUsageEvent"]>[0];
type RecordedLease = Parameters<VmRepositoryShape["recordLease"]>[0];
type ObservedStatusUpdate = Parameters<VmRepositoryShape["markProviderObservedStatus"]>[0];

function databaseURL() {
  const url = process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL;
  if (!url) {
    throw new Error("DATABASE_URL is required when CMUX_DB_TEST=1");
  }
  return url;
}

function providerLayer(
  provider: VmProviderGatewayShape,
  billing: VmBillingGatewayShape = noOpVmBillingGateway(),
) {
  return Layer.mergeAll(
    VmRepositoryLive,
    Layer.succeed(VmProviderGateway, provider),
    Layer.succeed(VmBillingGateway, billing),
  );
}

function workflowLayer(
  repo: VmRepositoryShape,
  provider: VmProviderGatewayShape,
  billing: VmBillingGatewayShape = noOpVmBillingGateway(),
) {
  return Layer.mergeAll(
    Layer.succeed(VmRepository, repo),
    Layer.succeed(VmProviderGateway, provider),
    Layer.succeed(VmBillingGateway, billing),
  );
}

beforeAll(() => {
  if (!runDbTests) return;
  sql = postgres(databaseURL(), { max: 1 });
});

afterAll(async () => {
  await closeCloudDbForTests();
  await sql?.end();
});

describe("VM Effect workflows", () => {
  test("exec resumes a paused VM, retries once, and records one usage event", async () => {
    const vm = testCloudVmRow({
      id: "00000000-0000-4000-8000-000000000101",
      userId: "user-workflow-exec-resume",
      billingTeamId: "team-workflow-exec-resume",
      providerVmId: "provider-vm-exec-resume",
      status: "running",
    });
    const usageEvents: RecordedUsageEvent[] = [];
    const observedStatuses: ObservedStatusUpdate[] = [];
    const repo = testWorkflowRepo({ vm, usageEvents, observedStatuses });
    const callOrder: string[] = [];
    let execCalls = 0;
    let statusCalls = 0;
    let resumeCalls = 0;
    const provider: VmProviderGatewayShape = {
      ...unusedProviderGateway(),
      exec: () =>
        Effect.suspend(() => {
          execCalls += 1;
          callOrder.push("exec");
          return Effect.succeed({ exitCode: 7, stdout: "preflight", stderr: "" });
        }),
      getStatus: () =>
        Effect.sync(() => {
          statusCalls += 1;
          callOrder.push("getStatus");
          return "paused" as const;
        }),
      resume: () =>
        Effect.sync(() => {
          resumeCalls += 1;
          callOrder.push("resume");
          return testVmHandle({ providerVmId: "provider-vm-exec-resume" });
        }),
    };

    const result = await Effect.runPromise(
      Effect.provide(
        execVm({
          userId: "user-workflow-exec-resume",
          providerVmId: "provider-vm-exec-resume",
          command: "echo preflight",
          timeoutMs: 1000,
        }),
        workflowLayer(repo, provider),
      ),
    );

    expect(result).toEqual({ exitCode: 7, stdout: "preflight", stderr: "" });
    expect(execCalls).toBe(1);
    expect(statusCalls).toBe(1);
    expect(resumeCalls).toBe(1);
    expect(callOrder).toEqual(["getStatus", "resume", "exec"]);
    expect(observedStatuses).toEqual([
      { id: vm.id, providerVmId: "provider-vm-exec-resume", status: "running" },
    ]);
    expect(usageEvents).toHaveLength(1);
    expect(usageEvents[0]).toMatchObject({
      eventType: "vm.exec",
      vmId: vm.id,
      metadata: { commandLength: "echo preflight".length, exitCode: 7 },
    });
  });

  test("exec failure with running provider status propagates the original error without retry", async () => {
    const vm = testCloudVmRow({
      id: "00000000-0000-4000-8000-000000000102",
      userId: "user-workflow-exec-running",
      providerVmId: "provider-vm-exec-running",
      status: "running",
    });
    const usageEvents: RecordedUsageEvent[] = [];
    const repo = testWorkflowRepo({ vm, usageEvents });
    const originalError = providerOperationError("exec", "provider exec unavailable");
    let execCalls = 0;
    let statusCalls = 0;
    let resumeCalls = 0;
    const provider: VmProviderGatewayShape = {
      ...unusedProviderGateway(),
      exec: () =>
        Effect.suspend(() => {
          execCalls += 1;
          return Effect.fail(originalError);
        }),
      getStatus: () =>
        Effect.sync(() => {
          statusCalls += 1;
          return "running" as const;
        }),
      resume: () =>
        Effect.sync(() => {
          resumeCalls += 1;
          return testVmHandle({ providerVmId: "provider-vm-exec-running" });
        }),
    };

    const error = await Effect.runPromise(
      Effect.provide(
        Effect.flip(
          execVm({
            userId: "user-workflow-exec-running",
            providerVmId: "provider-vm-exec-running",
            command: "true",
            timeoutMs: 1000,
          }),
        ),
        workflowLayer(repo, provider),
      ),
    );

    expect(error).toBe(originalError);
    expect(execCalls).toBe(1);
    expect(statusCalls).toBe(1);
    expect(resumeCalls).toBe(0);
    expect(usageEvents).toHaveLength(0);
  });

  test("exec preflight resume failure propagates the resume error without exec", async () => {
    const vm = testCloudVmRow({
      id: "00000000-0000-4000-8000-000000000103",
      userId: "user-workflow-exec-resume-fails",
      providerVmId: "provider-vm-exec-resume-fails",
      status: "running",
    });
    const repo = testWorkflowRepo({ vm });
    const resumeError = providerOperationError("resume", "provider resume unavailable");
    let execCalls = 0;
    let statusCalls = 0;
    let resumeCalls = 0;
    const provider: VmProviderGatewayShape = {
      ...unusedProviderGateway(),
      exec: () =>
        Effect.suspend(() => {
          execCalls += 1;
          return Effect.succeed({ exitCode: 0, stdout: "", stderr: "" });
        }),
      getStatus: () =>
        Effect.sync(() => {
          statusCalls += 1;
          return "paused" as const;
        }),
      resume: () =>
        Effect.suspend(() => {
          resumeCalls += 1;
          return Effect.fail(resumeError);
        }),
    };

    const error = await Effect.runPromise(
      Effect.provide(
        Effect.flip(
          execVm({
            userId: "user-workflow-exec-resume-fails",
            providerVmId: "provider-vm-exec-resume-fails",
            command: "true",
            timeoutMs: 1000,
          }),
        ),
        workflowLayer(repo, provider),
      ),
    );

    expect(error).toBe(resumeError);
    expect(execCalls).toBe(0);
    expect(statusCalls).toBe(1);
    expect(resumeCalls).toBe(1);
  });

  test("exec preflight fails with VmNotFoundError when resumed status persistence updates no row", async () => {
    const vm = testCloudVmRow({
      id: "00000000-0000-4000-8000-000000000112",
      userId: "user-workflow-exec-mark-false",
      providerVmId: "provider-vm-exec-mark-false",
      status: "running",
    });
    const repo = testWorkflowRepo({
      vm,
      markProviderObservedStatus: () => Effect.succeed(false),
    });
    let execCalls = 0;
    let statusCalls = 0;
    let resumeCalls = 0;
    const provider: VmProviderGatewayShape = {
      ...unusedProviderGateway(),
      exec: () =>
        Effect.sync(() => {
          execCalls += 1;
          return { exitCode: 0, stdout: "", stderr: "" };
        }),
      getStatus: () =>
        Effect.sync(() => {
          statusCalls += 1;
          return "paused" as const;
        }),
      resume: () =>
        Effect.sync(() => {
          resumeCalls += 1;
          return testVmHandle({ providerVmId: "provider-vm-exec-mark-false" });
        }),
    };

    const error = await Effect.runPromise(
      Effect.provide(
        Effect.flip(
          execVm({
            userId: "user-workflow-exec-mark-false",
            providerVmId: "provider-vm-exec-mark-false",
            command: "true",
            timeoutMs: 1000,
          }),
        ),
        workflowLayer(repo, provider),
      ),
    );

    expect(error).toBeInstanceOf(VmNotFoundError);
    expect(execCalls).toBe(0);
    expect(statusCalls).toBe(1);
    expect(resumeCalls).toBe(1);
  });

  test("exec failure without gateway getStatus propagates the original error", async () => {
    const vm = testCloudVmRow({
      id: "00000000-0000-4000-8000-000000000104",
      userId: "user-workflow-exec-no-status",
      providerVmId: "provider-vm-exec-no-status",
      status: "running",
    });
    const repo = testWorkflowRepo({ vm });
    const originalError = providerOperationError("exec", "provider exec unavailable");
    let execCalls = 0;
    let resumeCalls = 0;
    const provider: VmProviderGatewayShape = {
      ...unusedProviderGateway(),
      exec: () =>
        Effect.suspend(() => {
          execCalls += 1;
          return Effect.fail(originalError);
        }),
      resume: () =>
        Effect.sync(() => {
          resumeCalls += 1;
          return testVmHandle({ providerVmId: "provider-vm-exec-no-status" });
        }),
    };

    const error = await Effect.runPromise(
      Effect.provide(
        Effect.flip(
          execVm({
            userId: "user-workflow-exec-no-status",
            providerVmId: "provider-vm-exec-no-status",
            command: "true",
            timeoutMs: 1000,
          }),
        ),
        workflowLayer(repo, provider),
      ),
    );

    expect(error).toBe(originalError);
    expect(execCalls).toBe(1);
    expect(resumeCalls).toBe(0);
  });

  test("exec failure without gateway resume skips recovery and propagates the original error", async () => {
    const vm = testCloudVmRow({
      id: "00000000-0000-4000-8000-000000000107",
      userId: "user-workflow-exec-no-resume",
      providerVmId: "provider-vm-exec-no-resume",
      status: "running",
    });
    const usageEvents: RecordedUsageEvent[] = [];
    const repo = testWorkflowRepo({ vm, usageEvents });
    const originalError = providerOperationError("exec", "provider exec unavailable");
    let execCalls = 0;
    let statusCalls = 0;
    const provider: VmProviderGatewayShape = {
      ...unusedProviderGateway(),
      exec: () =>
        Effect.suspend(() => {
          execCalls += 1;
          return Effect.fail(originalError);
        }),
      getStatus: () =>
        Effect.sync(() => {
          statusCalls += 1;
          return "paused" as const;
        }),
    };

    const error = await Effect.runPromise(
      Effect.provide(
        Effect.flip(
          execVm({
            userId: "user-workflow-exec-no-resume",
            providerVmId: "provider-vm-exec-no-resume",
            command: "true",
            timeoutMs: 1000,
          }),
        ),
        workflowLayer(repo, provider),
      ),
    );

    expect(error).toBe(originalError);
    expect(execCalls).toBe(1);
    expect(statusCalls).toBe(0);
    expect(usageEvents).toHaveLength(0);
  });

  test("exec failure is not retried even if a later status check would report paused", async () => {
    const vm = testCloudVmRow({
      id: "00000000-0000-4000-8000-000000000108",
      userId: "user-workflow-exec-no-replay",
      providerVmId: "provider-vm-exec-no-replay",
      status: "running",
    });
    const usageEvents: RecordedUsageEvent[] = [];
    const repo = testWorkflowRepo({ vm, usageEvents });
    const originalError = providerOperationError("exec", "provider exec response dropped");
    let execCalls = 0;
    let statusCalls = 0;
    let resumeCalls = 0;
    const provider: VmProviderGatewayShape = {
      ...unusedProviderGateway(),
      exec: () =>
        Effect.suspend(() => {
          execCalls += 1;
          return Effect.fail(originalError);
        }),
      getStatus: () =>
        Effect.sync(() => {
          statusCalls += 1;
          if (statusCalls === 1) return "running" as const;
          return "paused" as const;
        }),
      resume: () =>
        Effect.sync(() => {
          resumeCalls += 1;
          return testVmHandle({ providerVmId: "provider-vm-exec-no-replay" });
        }),
    };

    const error = await Effect.runPromise(
      Effect.provide(
        Effect.flip(
          execVm({
            userId: "user-workflow-exec-no-replay",
            providerVmId: "provider-vm-exec-no-replay",
            command: "true",
            timeoutMs: 1000,
          }),
        ),
        workflowLayer(repo, provider),
      ),
    );

    expect(error).toBe(originalError);
    expect(execCalls).toBe(1);
    expect(statusCalls).toBe(1);
    expect(resumeCalls).toBe(0);
    expect(usageEvents).toHaveLength(0);
  });

  test("exec preflight getStatus failure still attempts exec once", async () => {
    const vm = testCloudVmRow({
      id: "00000000-0000-4000-8000-000000000109",
      userId: "user-workflow-exec-status-fails",
      providerVmId: "provider-vm-exec-status-fails",
      status: "running",
    });
    const usageEvents: RecordedUsageEvent[] = [];
    const repo = testWorkflowRepo({ vm, usageEvents });
    let execCalls = 0;
    let statusCalls = 0;
    let resumeCalls = 0;
    const provider: VmProviderGatewayShape = {
      ...unusedProviderGateway(),
      exec: () =>
        Effect.sync(() => {
          execCalls += 1;
          return { exitCode: 0, stdout: "ok", stderr: "" };
        }),
      getStatus: () =>
        Effect.suspend(() => {
          statusCalls += 1;
          return Effect.fail(providerOperationError("getStatus", "status unavailable"));
        }),
      resume: () =>
        Effect.sync(() => {
          resumeCalls += 1;
          return testVmHandle({ providerVmId: "provider-vm-exec-status-fails" });
        }),
    };

    const result = await Effect.runPromise(
      Effect.provide(
        execVm({
          userId: "user-workflow-exec-status-fails",
          providerVmId: "provider-vm-exec-status-fails",
          command: "true",
          timeoutMs: 1000,
        }),
        workflowLayer(repo, provider),
      ),
    );

    expect(result).toEqual({ exitCode: 0, stdout: "ok", stderr: "" });
    expect(execCalls).toBe(1);
    expect(statusCalls).toBe(1);
    expect(resumeCalls).toBe(0);
    expect(usageEvents).toHaveLength(1);
  });

  test("openAttachEndpoint preflight-resumes a paused VM before minting", async () => {
    const vm = testCloudVmRow({
      id: "00000000-0000-4000-8000-000000000105",
      userId: "user-workflow-attach-resume",
      billingTeamId: "team-workflow-attach-resume",
      providerVmId: "provider-vm-attach-resume",
      status: "running",
    });
    const usageEvents: RecordedUsageEvent[] = [];
    const leases: RecordedLease[] = [];
    const observedStatuses: ObservedStatusUpdate[] = [];
    const repo = testWorkflowRepo({ vm, usageEvents, leases, observedStatuses });
    const originalError = providerOperationError("openAttach", "provider attach unavailable");
    const endpoint = testAttachEndpoint();
    let attachCalls = 0;
    let statusCalls = 0;
    let resumeCalls = 0;
    const provider: VmProviderGatewayShape = {
      ...unusedProviderGateway(),
      openAttach: () =>
        Effect.suspend(() => {
          attachCalls += 1;
          return Effect.succeed(endpoint);
        }),
      getStatus: () =>
        Effect.sync(() => {
          statusCalls += 1;
          return "paused" as const;
        }),
      resume: () =>
        Effect.sync(() => {
          resumeCalls += 1;
          return testVmHandle({ providerVmId: "provider-vm-attach-resume" });
        }),
    };

    const result = await Effect.runPromise(
      Effect.provide(
        openAttachEndpoint({
          userId: "user-workflow-attach-resume",
          providerVmId: "provider-vm-attach-resume",
          options: { requireDaemon: true },
        }),
        workflowLayer(repo, provider),
      ),
    );

    expect(result).toEqual(endpoint);
    expect(attachCalls).toBe(1);
    expect(statusCalls).toBe(1);
    expect(resumeCalls).toBe(1);
    expect(observedStatuses).toEqual([
      { id: vm.id, providerVmId: "provider-vm-attach-resume", status: "running" },
    ]);
    expect(leases).toHaveLength(1);
    expect(usageEvents).toHaveLength(1);
    expect(usageEvents[0]).toMatchObject({
      eventType: "vm.attach",
      vmId: vm.id,
      metadata: { transport: "websocket", requireDaemon: true, daemonAvailable: false },
    });
  });

  test("openAttachEndpoint fails when resumed status persistence fails", async () => {
    const vm = testCloudVmRow({
      id: "00000000-0000-4000-8000-000000000110",
      userId: "user-workflow-attach-mark-fails",
      billingTeamId: "team-workflow-attach-mark-fails",
      providerVmId: "provider-vm-attach-mark-fails",
      status: "running",
    });
    const usageEvents: RecordedUsageEvent[] = [];
    const leases: RecordedLease[] = [];
    const markError = new VmDatabaseError({
      operation: "markProviderObservedStatus",
      cause: new Error("database unavailable"),
    });
    const repo = testWorkflowRepo({
      vm,
      usageEvents,
      leases,
      markProviderObservedStatus: () => Effect.fail(markError),
    });
    const originalError = providerOperationError("openAttach", "provider attach unavailable");
    let attachCalls = 0;
    let statusCalls = 0;
    let pauseCalls = 0;
    let resumeCalls = 0;
    const provider: VmProviderGatewayShape = {
      ...unusedProviderGateway(),
      openAttach: () =>
        Effect.suspend(() => {
          attachCalls += 1;
          if (attachCalls === 1) return Effect.fail(originalError);
          return Effect.succeed(testAttachEndpoint());
        }),
      getStatus: () =>
        Effect.sync(() => {
          statusCalls += 1;
          return "paused" as const;
        }),
      resume: () =>
        Effect.sync(() => {
          resumeCalls += 1;
          return testVmHandle({ providerVmId: "provider-vm-attach-mark-fails" });
        }),
      pause: () =>
        Effect.sync(() => {
          pauseCalls += 1;
        }),
    };

    const error = await Effect.runPromise(
      Effect.provide(
        Effect.flip(
          openAttachEndpoint({
            userId: "user-workflow-attach-mark-fails",
            providerVmId: "provider-vm-attach-mark-fails",
          }),
        ),
        workflowLayer(repo, provider),
      ),
    );

    expect(error).toBe(markError);
    expect(attachCalls).toBe(0);
    expect(statusCalls).toBe(1);
    expect(resumeCalls).toBe(1);
    expect(pauseCalls).toBe(1);
    expect(leases).toHaveLength(0);
    expect(usageEvents).toHaveLength(0);
  });

  test("openAttachEndpoint fails when resumed status persistence updates no row", async () => {
    const vm = testCloudVmRow({
      id: "00000000-0000-4000-8000-000000000111",
      userId: "user-workflow-attach-mark-false",
      billingTeamId: "team-workflow-attach-mark-false",
      providerVmId: "provider-vm-attach-mark-false",
      status: "running",
    });
    const usageEvents: RecordedUsageEvent[] = [];
    const leases: RecordedLease[] = [];
    const repo = testWorkflowRepo({
      vm,
      usageEvents,
      leases,
      markProviderObservedStatus: () => Effect.succeed(false),
    });
    const originalError = providerOperationError("openAttach", "provider attach unavailable");
    let attachCalls = 0;
    let statusCalls = 0;
    let pauseCalls = 0;
    let resumeCalls = 0;
    const provider: VmProviderGatewayShape = {
      ...unusedProviderGateway(),
      openAttach: () =>
        Effect.suspend(() => {
          attachCalls += 1;
          if (attachCalls === 1) return Effect.fail(originalError);
          return Effect.succeed(testAttachEndpoint());
        }),
      getStatus: () =>
        Effect.sync(() => {
          statusCalls += 1;
          return "paused" as const;
        }),
      resume: () =>
        Effect.sync(() => {
          resumeCalls += 1;
          return testVmHandle({ providerVmId: "provider-vm-attach-mark-false" });
        }),
      pause: () =>
        Effect.sync(() => {
          pauseCalls += 1;
        }),
    };

    const error = await Effect.runPromise(
      Effect.provide(
        Effect.flip(
          openAttachEndpoint({
            userId: "user-workflow-attach-mark-false",
            providerVmId: "provider-vm-attach-mark-false",
          }),
        ),
        workflowLayer(repo, provider),
      ),
    );

    expect(error).toBeInstanceOf(VmNotFoundError);
    expect(attachCalls).toBe(0);
    expect(statusCalls).toBe(1);
    expect(resumeCalls).toBe(1);
    expect(pauseCalls).toBe(1);
    expect(leases).toHaveLength(0);
    expect(usageEvents).toHaveLength(0);
  });

  test("openSshEndpoint preflight-resumes a paused VM before minting", async () => {
    const vm = testCloudVmRow({
      id: "00000000-0000-4000-8000-000000000106",
      userId: "user-workflow-ssh-resume",
      billingTeamId: "team-workflow-ssh-resume",
      providerVmId: "provider-vm-ssh-resume",
      status: "running",
    });
    const usageEvents: RecordedUsageEvent[] = [];
    const leases: RecordedLease[] = [];
    const observedStatuses: ObservedStatusUpdate[] = [];
    const repo = testWorkflowRepo({ vm, usageEvents, leases, observedStatuses });
    const originalError = providerOperationError("openSSH", "provider ssh unavailable");
    const endpoint = testSshEndpoint();
    let sshCalls = 0;
    let statusCalls = 0;
    let resumeCalls = 0;
    const provider: VmProviderGatewayShape = {
      ...unusedProviderGateway(),
      openSSH: () =>
        Effect.suspend(() => {
          sshCalls += 1;
          return Effect.succeed(endpoint);
        }),
      getStatus: () =>
        Effect.sync(() => {
          statusCalls += 1;
          return "paused" as const;
        }),
      resume: () =>
        Effect.sync(() => {
          resumeCalls += 1;
          return testVmHandle({ providerVmId: "provider-vm-ssh-resume" });
        }),
    };

    const result = await Effect.runPromise(
      Effect.provide(
        openSshEndpoint({
          userId: "user-workflow-ssh-resume",
          providerVmId: "provider-vm-ssh-resume",
        }),
        workflowLayer(repo, provider),
      ),
    );

    expect(result).toEqual(endpoint);
    expect(sshCalls).toBe(1);
    expect(statusCalls).toBe(1);
    expect(resumeCalls).toBe(1);
    expect(observedStatuses).toEqual([
      { id: vm.id, providerVmId: "provider-vm-ssh-resume", status: "running" },
    ]);
    expect(leases).toHaveLength(1);
    expect(usageEvents).toHaveLength(1);
    expect(usageEvents[0]).toMatchObject({
      eventType: "vm.ssh_endpoint",
      vmId: vm.id,
      metadata: { credentialKind: "password" },
    });
  });

  test("openAttachEndpoint recovers when the VM suspends between preflight and minting", async () => {
    const vm = testCloudVmRow({
      id: "00000000-0000-4000-8000-000000000112",
      userId: "user-workflow-attach-race",
      billingTeamId: "team-workflow-attach-race",
      providerVmId: "provider-vm-attach-race",
      status: "running",
    });
    const usageEvents: RecordedUsageEvent[] = [];
    const leases: RecordedLease[] = [];
    const observedStatuses: ObservedStatusUpdate[] = [];
    const repo = testWorkflowRepo({ vm, usageEvents, leases, observedStatuses });
    const originalError = providerOperationError("openAttach", "provider attach unavailable");
    const endpoint = testAttachEndpoint();
    let attachCalls = 0;
    let statusCalls = 0;
    let resumeCalls = 0;
    const provider: VmProviderGatewayShape = {
      ...unusedProviderGateway(),
      openAttach: () =>
        Effect.suspend(() => {
          attachCalls += 1;
          if (attachCalls === 1) return Effect.fail(originalError);
          return Effect.succeed(endpoint);
        }),
      getStatus: () =>
        Effect.sync(() => {
          statusCalls += 1;
          // Running at preflight, paused when the mint failure is investigated.
          return statusCalls === 1 ? ("running" as const) : ("paused" as const);
        }),
      resume: () =>
        Effect.sync(() => {
          resumeCalls += 1;
          return testVmHandle({ providerVmId: "provider-vm-attach-race" });
        }),
    };

    const result = await Effect.runPromise(
      Effect.provide(
        openAttachEndpoint({
          userId: "user-workflow-attach-race",
          providerVmId: "provider-vm-attach-race",
        }),
        workflowLayer(repo, provider),
      ),
    );

    expect(result).toEqual(endpoint);
    expect(attachCalls).toBe(2);
    expect(statusCalls).toBe(2);
    expect(resumeCalls).toBe(1);
    expect(observedStatuses).toEqual([
      { id: vm.id, providerVmId: "provider-vm-attach-race", status: "running" },
    ]);
    expect(leases).toHaveLength(1);
    expect(usageEvents).toHaveLength(1);
  });

  test("openAttachEndpoint fails closed when the row is paused and the status probe fails", async () => {
    const vm = testCloudVmRow({
      id: "00000000-0000-4000-8000-000000000113",
      userId: "user-workflow-attach-probe-fail",
      billingTeamId: "team-workflow-attach-probe-fail",
      providerVmId: "provider-vm-attach-probe-fail",
      status: "paused",
    });
    const usageEvents: RecordedUsageEvent[] = [];
    const leases: RecordedLease[] = [];
    const repo = testWorkflowRepo({ vm, usageEvents, leases });
    const probeError = providerOperationError("getStatus", "provider status unavailable");
    let attachCalls = 0;
    let resumeCalls = 0;
    const provider: VmProviderGatewayShape = {
      ...unusedProviderGateway(),
      openAttach: () =>
        Effect.suspend(() => {
          attachCalls += 1;
          return Effect.succeed(testAttachEndpoint());
        }),
      getStatus: () => Effect.fail(probeError),
      resume: () =>
        Effect.sync(() => {
          resumeCalls += 1;
          return testVmHandle({ providerVmId: "provider-vm-attach-probe-fail" });
        }),
    };

    const error = await Effect.runPromise(
      Effect.provide(
        Effect.flip(
          openAttachEndpoint({
            userId: "user-workflow-attach-probe-fail",
            providerVmId: "provider-vm-attach-probe-fail",
          }),
        ),
        workflowLayer(repo, provider),
      ),
    );

    expect(error).toBe(probeError);
    expect(attachCalls).toBe(0);
    expect(resumeCalls).toBe(0);
    expect(leases).toHaveLength(0);
    expect(usageEvents).toHaveLength(0);
  });

  test("exec waits for a not-yet-running resume handle to settle before running", async () => {
    const vm = testCloudVmRow({
      id: "00000000-0000-4000-8000-000000000114",
      userId: "user-workflow-exec-settle",
      billingTeamId: "team-workflow-exec-settle",
      providerVmId: "provider-vm-exec-settle",
      status: "paused",
    });
    const usageEvents: RecordedUsageEvent[] = [];
    const observedStatuses: ObservedStatusUpdate[] = [];
    const repo = testWorkflowRepo({ vm, usageEvents, observedStatuses });
    let execCalls = 0;
    let statusCalls = 0;
    const provider: VmProviderGatewayShape = {
      ...unusedProviderGateway(),
      exec: () =>
        Effect.suspend(() => {
          execCalls += 1;
          return Effect.succeed({ exitCode: 0, stdout: "ok", stderr: "" });
        }),
      getStatus: () =>
        Effect.sync(() => {
          statusCalls += 1;
          // Preflight probe sees paused; the settle poll after resume sees running.
          return statusCalls === 1 ? ("paused" as const) : ("running" as const);
        }),
      resume: () =>
        Effect.succeed({
          provider: "freestyle" as const,
          providerVmId: "provider-vm-exec-settle",
          status: "creating" as const,
          image: "freestyle:resumed",
          createdAt: Date.now(),
        }),
    };

    const result = await Effect.runPromise(
      Effect.provide(
        execVm({
          userId: "user-workflow-exec-settle",
          providerVmId: "provider-vm-exec-settle",
          command: "echo ok",
          timeoutMs: 1000,
        }),
        workflowLayer(repo, provider),
      ),
    );

    expect(result.exitCode).toBe(0);
    expect(execCalls).toBe(1);
    expect(statusCalls).toBe(2);
    expect(observedStatuses).toEqual([
      { id: vm.id, providerVmId: "provider-vm-exec-settle", status: "running" },
    ]);
  });

  test("exec waits out a concurrent resume (creating) without resuming or recording", async () => {
    const vm = testCloudVmRow({
      id: "00000000-0000-4000-8000-000000000115",
      userId: "user-workflow-exec-concurrent",
      billingTeamId: "team-workflow-exec-concurrent",
      providerVmId: "provider-vm-exec-concurrent",
      status: "paused",
    });
    const usageEvents: RecordedUsageEvent[] = [];
    const observedStatuses: ObservedStatusUpdate[] = [];
    const repo = testWorkflowRepo({ vm, usageEvents, observedStatuses });
    let execCalls = 0;
    let statusCalls = 0;
    let resumeCalls = 0;
    const provider: VmProviderGatewayShape = {
      ...unusedProviderGateway(),
      exec: () =>
        Effect.suspend(() => {
          execCalls += 1;
          return Effect.succeed({ exitCode: 0, stdout: "ok", stderr: "" });
        }),
      getStatus: () =>
        Effect.sync(() => {
          statusCalls += 1;
          // Another caller's resume is in flight; it settles on the next poll.
          return statusCalls === 1 ? ("creating" as const) : ("running" as const);
        }),
      resume: () =>
        Effect.sync(() => {
          resumeCalls += 1;
          return testVmHandle({ providerVmId: "provider-vm-exec-concurrent" });
        }),
    };

    const result = await Effect.runPromise(
      Effect.provide(
        execVm({
          userId: "user-workflow-exec-concurrent",
          providerVmId: "provider-vm-exec-concurrent",
          command: "echo ok",
          timeoutMs: 1000,
        }),
        workflowLayer(repo, provider),
      ),
    );

    expect(result.exitCode).toBe(0);
    expect(execCalls).toBe(1);
    expect(resumeCalls).toBe(0);
    expect(statusCalls).toBe(2);
    // The waiter persists the observed running state itself in case the
    // resuming caller dies before its own durable write.
    expect(observedStatuses).toEqual([
      { id: vm.id, providerVmId: "provider-vm-exec-concurrent", status: "running" },
    ]);
  });

  dbTest("does not block create when usage event recording fails", async () => {
    const requested = testCloudVmRow({
      status: "provisioning",
      providerVmId: null,
    });
    const running = testCloudVmRow({
      status: "running",
      providerVmId: "provider-vm-usage-events",
      imageVersion: "test-version",
    });
    let providerCreateCalls = 0;
    let usageEventAttempts = 0;
    const repo: VmRepositoryShape = {
      listUserVms: () => Effect.succeed([]),
      claimBillingGrant: () => Effect.succeed({ kind: "already_claimed" }),
      markBillingGrantApplied: () => Effect.void,
      deleteBillingGrant: () => Effect.void,
      beginCreate: () => Effect.succeed({ inserted: true, vm: requested }),
      activeLimitCandidates: () => Effect.succeed([]),
      markProviderObservedStatus: () => Effect.succeed(false),
      markCreateRunning: () => Effect.succeed(running),
      markCreateFailed: () => Effect.void,
      findUserVm: () => Effect.succeed(null),
      markDestroyed: () => Effect.void,
      recordLease: () => Effect.void,
      activeIdentityLeases: () => Effect.succeed([]),
      markLeasesRevoked: () => Effect.void,
      recordUsageEvent: () => Effect.void,
      recordUsageEvents: () => {
        usageEventAttempts += 1;
        return Effect.fail(new VmDatabaseError({
          operation: "recordUsageEvents",
          cause: new Error("usage event table unavailable"),
        }));
      },
    };
    const provider: VmProviderGatewayShape = {
      create: () =>
        Effect.sync(() => {
          providerCreateCalls += 1;
          return {
            provider: "freestyle" as const,
            providerVmId: "provider-vm-usage-events",
            status: "running" as const,
            image: "snapshot-test",
            createdAt: Date.now(),
          };
        }),
      destroy: () => Effect.void,
      exec: () => Effect.succeed({ exitCode: 0, stdout: "", stderr: "" }),
      openAttach: () => Effect.fail(new Error("unused") as never),
      openSSH: () => Effect.fail(new Error("unused") as never),
      revokeSSHIdentity: () => Effect.void,
    };
    const layer = Layer.mergeAll(
      Layer.succeed(VmRepository, repo),
      Layer.succeed(VmProviderGateway, provider),
      Layer.succeed(VmBillingGateway, noOpVmBillingGateway()),
    );

    const created = await Effect.runPromise(
      createVm({
        userId: "user-workflow-usage-events",
        billingCustomerType: "team",
        billingTeamId: "team-workflow-usage-events",
        billingPlanId: "free",
        maxActiveVms: 1,
        provider: "freestyle",
        image: "snapshot-test",
        imageVersion: "test-version",
        idempotencyKey: "usage-events",
      }).pipe(Effect.provide(layer)),
    );

    expect(created.providerVmId).toBe("provider-vm-usage-events");
    expect(providerCreateCalls).toBe(1);
    expect(usageEventAttempts).toBe(2);
  });

  dbTest("creates one provider VM per user idempotency key and records usage", async () => {
    if (!sql) throw new Error("test database not initialized");
    await sql`truncate cloud_vm_billing_grants, cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;

    let createCalls = 0;
    const provider: VmProviderGatewayShape = {
      create: () =>
        Effect.sync(() => {
          createCalls += 1;
          return {
            provider: "e2b" as const,
            providerVmId: "provider-vm-idem-1",
            status: "running" as const,
            image: "cmuxd-ws:test",
            createdAt: Date.now(),
          };
        }),
      destroy: () => Effect.void,
      exec: () => Effect.succeed({ exitCode: 0, stdout: "", stderr: "" }),
      openAttach: () => Effect.fail(new Error("unused") as never),
      openSSH: () => Effect.fail(new Error("unused") as never),
      revokeSSHIdentity: () => Effect.void,
    };

    const program = createVm({
      userId: "user-workflow-idem",
      billingCustomerType: "team",
      billingTeamId: "team-workflow-idem",
      billingPlanId: "free",
      maxActiveVms: 1,
      provider: "e2b",
      image: "cmuxd-ws:test",
      imageVersion: "test-version",
      idempotencyKey: "idem-1",
    });
    const layer = providerLayer(provider);
    const first = await Effect.runPromise(program.pipe(Effect.provide(layer)));
    const second = await Effect.runPromise(program.pipe(Effect.provide(layer)));

    expect(first).toEqual(second);
    expect(createCalls).toBe(1);

    const [{ vmCount }] = await sql<{ vmCount: string }[]>`
      select count(*)::text as "vmCount" from cloud_vms where user_id = 'user-workflow-idem'
    `;
    const [{ usageCount }] = await sql<{ usageCount: string }[]>`
      select count(*)::text as "usageCount" from cloud_vm_usage_events
      where user_id = 'user-workflow-idem' and event_type = 'vm.created'
    `;
    const [{ imageVersion }] = await sql<{ imageVersion: string | null }[]>`
      select image_version as "imageVersion" from cloud_vms where user_id = 'user-workflow-idem'
    `;
    expect(vmCount).toBe("1");
    expect(usageCount).toBe("1");
    expect(imageVersion).toBe("test-version");
  });

  dbTest("revokes the previous SSH identity before minting a replacement", async () => {
    if (!sql) throw new Error("test database not initialized");
    await sql`truncate cloud_vm_billing_grants, cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;
    const [vm] = await sql<{ id: string }[]>`
      insert into cloud_vms (user_id, provider, provider_vm_id, image_id, status)
      values ('user-workflow-ssh', 'freestyle', 'provider-vm-ssh-1', 'snapshot-test', 'running')
      returning id
    `;

    let mintCount = 0;
    const revoked: string[] = [];
    const provider: VmProviderGatewayShape = {
      create: () => Effect.fail(new Error("unused") as never),
      destroy: () => Effect.void,
      exec: () => Effect.succeed({ exitCode: 0, stdout: "", stderr: "" }),
      openAttach: () => Effect.fail(new Error("unused") as never),
      openSSH: () =>
        Effect.sync(() => {
          mintCount += 1;
          return {
            transport: "ssh" as const,
            host: "vm-ssh.freestyle.sh",
            port: 22,
            username: "provider-vm-ssh-1+cmux",
            publicKeyFingerprint: null,
            credential: { kind: "password" as const, value: `token-${mintCount}` },
            identityHandle: `identity-${mintCount}`,
          };
        }),
      revokeSSHIdentity: (_provider, identityHandle) =>
        Effect.sync(() => {
          revoked.push(identityHandle);
        }),
    };
    const layer = providerLayer(provider);

    const endpoint1 = await Effect.runPromise(
      openSshEndpoint({ userId: "user-workflow-ssh", providerVmId: "provider-vm-ssh-1" }).pipe(
        Effect.provide(layer),
      ),
    );
    const endpoint2 = await Effect.runPromise(
      openSshEndpoint({ userId: "user-workflow-ssh", providerVmId: "provider-vm-ssh-1" }).pipe(
        Effect.provide(layer),
      ),
    );

    expect(endpoint1.identityHandle).toBe("identity-1");
    expect(endpoint2.identityHandle).toBe("identity-2");
    expect(revoked).toEqual(["identity-1"]);

    const leases = await sql<{ providerIdentityHandle: string; revokedAt: Date | null }[]>`
      select provider_identity_handle as "providerIdentityHandle", revoked_at as "revokedAt"
      from cloud_vm_leases
      where vm_id = ${vm.id}
      order by provider_identity_handle
    `;
    expect(leases).toHaveLength(2);
    expect(leases[0]).toMatchObject({ providerIdentityHandle: "identity-1" });
    expect(leases[0]?.revokedAt).toBeInstanceOf(Date);
    expect(leases[1]).toMatchObject({ providerIdentityHandle: "identity-2", revokedAt: null });
  });

  dbTest("enforces active VM limits per billing team before provider create", async () => {
    if (!sql) throw new Error("test database not initialized");
    await sql`truncate cloud_vm_billing_grants, cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;
    await sql`
      insert into cloud_vms (user_id, billing_team_id, billing_plan_id, provider, provider_vm_id, image_id, status)
      values ('user-workflow-limit-owner', 'team-workflow-limit', 'free', 'e2b', 'provider-vm-limit-1', 'cmuxd-ws:test', 'running')
    `;

    let createCalls = 0;
    const provider: VmProviderGatewayShape = {
      create: () =>
        Effect.sync(() => {
          createCalls += 1;
          return {
            provider: "e2b" as const,
            providerVmId: "provider-vm-limit-2",
            status: "running" as const,
            image: "cmuxd-ws:test",
            createdAt: Date.now(),
          };
        }),
      destroy: () => Effect.void,
      exec: () => Effect.succeed({ exitCode: 0, stdout: "", stderr: "" }),
      openAttach: () => Effect.fail(new Error("unused") as never),
      openSSH: () => Effect.fail(new Error("unused") as never),
      revokeSSHIdentity: () => Effect.void,
    };

    const error = await Effect.runPromise(
      createVm({
        userId: "user-workflow-limit-new",
        billingCustomerType: "team",
        billingTeamId: "team-workflow-limit",
        billingPlanId: "free",
        maxActiveVms: 1,
        provider: "e2b",
        image: "cmuxd-ws:test",
        idempotencyKey: "limit-new-1",
      }).pipe(
        Effect.flip,
        Effect.provide(providerLayer(provider)),
      ),
    );

    expect(error).toBeInstanceOf(VmLimitExceededError);
    expect(createCalls).toBe(0);
  });

  dbTest("does not count paused VMs against the active billing team limit", async () => {
    if (!sql) throw new Error("test database not initialized");
    await sql`truncate cloud_vm_billing_grants, cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;
    await sql`
      insert into cloud_vms (user_id, billing_team_id, billing_plan_id, provider, provider_vm_id, image_id, status)
      values ('user-workflow-paused-slot-old', 'team-workflow-paused-slot', 'free', 'freestyle', 'provider-vm-paused-old', 'snapshot-test', 'paused')
    `;

    let createCalls = 0;
    let statusCalls = 0;
    const provider: VmProviderGatewayShape = {
      create: () =>
        Effect.sync(() => {
          createCalls += 1;
          return {
            provider: "freestyle" as const,
            providerVmId: "provider-vm-paused-new",
            status: "running" as const,
            image: "snapshot-test",
            createdAt: Date.now(),
          };
        }),
      destroy: () => Effect.void,
      exec: () => Effect.succeed({ exitCode: 0, stdout: "", stderr: "" }),
      openAttach: () => Effect.fail(new Error("unused") as never),
      openSSH: () => Effect.fail(new Error("unused") as never),
      revokeSSHIdentity: () => Effect.void,
      getStatus: () =>
        Effect.sync(() => {
          statusCalls += 1;
          return "running" as const;
        }),
    };

    const created = await Effect.runPromise(
      createVm({
        userId: "user-workflow-paused-slot-new",
        billingCustomerType: "team",
        billingTeamId: "team-workflow-paused-slot",
        billingPlanId: "free",
        maxActiveVms: 1,
        provider: "freestyle",
        image: "snapshot-test",
        idempotencyKey: "paused-slot-new",
      }).pipe(Effect.provide(providerLayer(provider))),
    );

    expect(created.providerVmId).toBe("provider-vm-paused-new");
    expect(createCalls).toBe(1);
    expect(statusCalls).toBe(0);
  });

  dbTest("skips Freestyle provider refresh when the billing team is below the active limit", async () => {
    if (!sql) throw new Error("test database not initialized");
    await sql`truncate cloud_vm_billing_grants, cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;
    await sql`
      insert into cloud_vms (user_id, billing_team_id, billing_plan_id, provider, provider_vm_id, image_id, status)
      values ('user-workflow-under-limit-old', 'team-workflow-under-limit', 'free', 'freestyle', 'provider-vm-under-limit-old', 'snapshot-test', 'running')
    `;

    let createCalls = 0;
    let statusCalls = 0;
    const provider: VmProviderGatewayShape = {
      create: () =>
        Effect.sync(() => {
          createCalls += 1;
          return {
            provider: "freestyle" as const,
            providerVmId: "provider-vm-under-limit-new",
            status: "running" as const,
            image: "snapshot-test",
            createdAt: Date.now(),
          };
        }),
      destroy: () => Effect.void,
      exec: () => Effect.succeed({ exitCode: 0, stdout: "", stderr: "" }),
      openAttach: () => Effect.fail(new Error("unused") as never),
      openSSH: () => Effect.fail(new Error("unused") as never),
      revokeSSHIdentity: () => Effect.void,
      getStatus: () =>
        Effect.sync(() => {
          statusCalls += 1;
          return "running" as const;
        }),
    };

    const created = await Effect.runPromise(
      createVm({
        userId: "user-workflow-under-limit-new",
        billingCustomerType: "team",
        billingTeamId: "team-workflow-under-limit",
        billingPlanId: "free",
        maxActiveVms: 2,
        provider: "freestyle",
        image: "snapshot-test",
        idempotencyKey: "under-limit-new",
      }).pipe(Effect.provide(providerLayer(provider))),
    );

    expect(created.providerVmId).toBe("provider-vm-under-limit-new");
    expect(statusCalls).toBe(0);
    expect(createCalls).toBe(1);
  });

  dbTest("refreshes Freestyle running rows before active limit enforcement", async () => {
    if (!sql) throw new Error("test database not initialized");
    await sql`truncate cloud_vm_billing_grants, cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;
    await sql`
      insert into cloud_vms (user_id, billing_team_id, billing_plan_id, provider, provider_vm_id, image_id, status)
      values ('user-workflow-provider-paused-old', 'team-workflow-provider-paused', 'free', 'freestyle', 'provider-vm-provider-paused-old', 'snapshot-test', 'running')
    `;

    let createCalls = 0;
    let statusCalls = 0;
    const provider: VmProviderGatewayShape = {
      create: () =>
        Effect.sync(() => {
          createCalls += 1;
          return {
            provider: "freestyle" as const,
            providerVmId: "provider-vm-provider-paused-new",
            status: "running" as const,
            image: "snapshot-test",
            createdAt: Date.now(),
          };
        }),
      destroy: () => Effect.void,
      exec: () => Effect.succeed({ exitCode: 0, stdout: "", stderr: "" }),
      openAttach: () => Effect.fail(new Error("unused") as never),
      openSSH: () => Effect.fail(new Error("unused") as never),
      revokeSSHIdentity: () => Effect.void,
      getStatus: () =>
        Effect.sync(() => {
          statusCalls += 1;
          return "paused" as const;
        }),
    };

    const created = await Effect.runPromise(
      createVm({
        userId: "user-workflow-provider-paused-new",
        billingCustomerType: "team",
        billingTeamId: "team-workflow-provider-paused",
        billingPlanId: "free",
        maxActiveVms: 1,
        provider: "freestyle",
        image: "snapshot-test",
        idempotencyKey: "provider-paused-new",
      }).pipe(Effect.provide(providerLayer(provider))),
    );

    expect(created.providerVmId).toBe("provider-vm-provider-paused-new");
    expect(statusCalls).toBe(1);
    expect(createCalls).toBe(1);

    const [oldVm] = await sql<{ status: string }[]>`
      select status from cloud_vms
      where provider_vm_id = 'provider-vm-provider-paused-old'
    `;
    expect(oldVm?.status).toBe("paused");
  });

  dbTest("marks provider-deleted Freestyle rows destroyed before active limit enforcement", async () => {
    if (!sql) throw new Error("test database not initialized");
    await sql`truncate cloud_vm_billing_grants, cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;
    await sql`
      insert into cloud_vms (user_id, billing_team_id, billing_plan_id, provider, provider_vm_id, image_id, status)
      values ('user-workflow-provider-deleted-old', 'team-workflow-provider-deleted', 'free', 'freestyle', 'provider-vm-provider-deleted-old', 'snapshot-test', 'running')
    `;

    let createCalls = 0;
    let statusCalls = 0;
    const provider: VmProviderGatewayShape = {
      create: () =>
        Effect.sync(() => {
          createCalls += 1;
          return {
            provider: "freestyle" as const,
            providerVmId: "provider-vm-provider-deleted-new",
            status: "running" as const,
            image: "snapshot-test",
            createdAt: Date.now(),
          };
        }),
      destroy: () => Effect.void,
      exec: () => Effect.succeed({ exitCode: 0, stdout: "", stderr: "" }),
      openAttach: () => Effect.fail(new Error("unused") as never),
      openSSH: () => Effect.fail(new Error("unused") as never),
      revokeSSHIdentity: () => Effect.void,
      getStatus: () =>
        Effect.suspend(() => {
          statusCalls += 1;
          const deleted = new Error(
            "VM_DELETED: Vm provider-vm-provider-deleted-old is marked as deleted but still exists in the database",
          );
          deleted.name = "VmDeletedError";
          return Effect.fail(new VmProviderOperationError({
            provider: "freestyle",
            operation: "getStatus",
            cause: deleted,
          }));
        }),
    };

    const created = await Effect.runPromise(
      createVm({
        userId: "user-workflow-provider-deleted-new",
        billingCustomerType: "team",
        billingTeamId: "team-workflow-provider-deleted",
        billingPlanId: "free",
        maxActiveVms: 1,
        provider: "freestyle",
        image: "snapshot-test",
        idempotencyKey: "provider-deleted-new",
      }).pipe(Effect.provide(providerLayer(provider))),
    );

    expect(created.providerVmId).toBe("provider-vm-provider-deleted-new");
    expect(statusCalls).toBe(1);
    expect(createCalls).toBe(1);

    const [oldVm] = await sql<{ status: string; destroyedAt: Date | null }[]>`
      select status, destroyed_at as "destroyedAt" from cloud_vms
      where provider_vm_id = 'provider-vm-provider-deleted-old'
    `;
    expect(oldVm?.status).toBe("destroyed");
    expect(oldVm?.destroyedAt).toBeInstanceOf(Date);

    const [{ destroyedUsageCount }] = await sql<{ destroyedUsageCount: string }[]>`
      select count(*)::text as "destroyedUsageCount"
      from cloud_vm_usage_events
      where provider = 'freestyle'
        and event_type = 'vm.destroyed'
        and vm_id in (
          select id from cloud_vms
          where provider_vm_id = 'provider-vm-provider-deleted-old'
        )
    `;
    expect(destroyedUsageCount).toBe("1");
  });

  dbTest("refreshes Freestyle running rows concurrently before active limit enforcement", async () => {
    if (!sql) throw new Error("test database not initialized");
    await sql`truncate cloud_vm_billing_grants, cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;
    await sql`
      insert into cloud_vms (user_id, billing_team_id, billing_plan_id, provider, provider_vm_id, image_id, status)
      values
        ('user-workflow-provider-concurrent-old-1', 'team-workflow-provider-concurrent', 'free', 'freestyle', 'provider-vm-provider-concurrent-old-1', 'snapshot-test', 'running'),
        ('user-workflow-provider-concurrent-old-2', 'team-workflow-provider-concurrent', 'free', 'freestyle', 'provider-vm-provider-concurrent-old-2', 'snapshot-test', 'running')
    `;

    let createCalls = 0;
    let statusCalls = 0;
    let inFlight = 0;
    let maxInFlight = 0;
    const provider: VmProviderGatewayShape = {
      create: () =>
        Effect.sync(() => {
          createCalls += 1;
          return {
            provider: "freestyle" as const,
            providerVmId: "provider-vm-provider-concurrent-new",
            status: "running" as const,
            image: "snapshot-test",
            createdAt: Date.now(),
          };
        }),
      destroy: () => Effect.void,
      exec: () => Effect.succeed({ exitCode: 0, stdout: "", stderr: "" }),
      openAttach: () => Effect.fail(new Error("unused") as never),
      openSSH: () => Effect.fail(new Error("unused") as never),
      revokeSSHIdentity: () => Effect.void,
      getStatus: () =>
        Effect.promise(async () => {
          statusCalls += 1;
          inFlight += 1;
          maxInFlight = Math.max(maxInFlight, inFlight);
          await Promise.resolve();
          inFlight -= 1;
          return "paused" as const;
        }),
    };

    const created = await Effect.runPromise(
      createVm({
        userId: "user-workflow-provider-concurrent-new",
        billingCustomerType: "team",
        billingTeamId: "team-workflow-provider-concurrent",
        billingPlanId: "free",
        maxActiveVms: 1,
        provider: "freestyle",
        image: "snapshot-test",
        idempotencyKey: "provider-concurrent-new",
      }).pipe(Effect.provide(providerLayer(provider))),
    );

    expect(created.providerVmId).toBe("provider-vm-provider-concurrent-new");
    expect(statusCalls).toBe(2);
    expect(maxInFlight).toBe(2);
    expect(createCalls).toBe(1);

    const [{ oldRunningCount }] = await sql<{ oldRunningCount: string }[]>`
      select count(*)::text as "oldRunningCount" from cloud_vms
      where billing_team_id = 'team-workflow-provider-concurrent'
        and provider_vm_id like 'provider-vm-provider-concurrent-old-%'
        and status = 'running'
    `;
    expect(oldRunningCount).toBe("0");
  });

  dbTest("does not regress running rows when Freestyle reports creating", async () => {
    if (!sql) throw new Error("test database not initialized");
    await sql`truncate cloud_vm_billing_grants, cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;
    await sql`
      insert into cloud_vms (user_id, billing_team_id, billing_plan_id, provider, provider_vm_id, image_id, status)
      values ('user-workflow-provider-creating-old', 'team-workflow-provider-creating', 'free', 'freestyle', 'provider-vm-provider-creating-old', 'snapshot-test', 'running')
    `;

    let createCalls = 0;
    let statusCalls = 0;
    const provider: VmProviderGatewayShape = {
      create: () =>
        Effect.sync(() => {
          createCalls += 1;
          throw new Error("provider create should not be called");
        }),
      destroy: () => Effect.void,
      exec: () => Effect.succeed({ exitCode: 0, stdout: "", stderr: "" }),
      openAttach: () => Effect.fail(new Error("unused") as never),
      openSSH: () => Effect.fail(new Error("unused") as never),
      revokeSSHIdentity: () => Effect.void,
      getStatus: () =>
        Effect.sync(() => {
          statusCalls += 1;
          return "creating" as const;
        }),
    };

    const error = await Effect.runPromise(
      createVm({
        userId: "user-workflow-provider-creating-new",
        billingCustomerType: "team",
        billingTeamId: "team-workflow-provider-creating",
        billingPlanId: "free",
        maxActiveVms: 1,
        provider: "freestyle",
        image: "snapshot-test",
        idempotencyKey: "provider-creating-new",
      }).pipe(
        Effect.flip,
        Effect.provide(providerLayer(provider)),
      ),
    );

    expect(error).toBeInstanceOf(VmLimitExceededError);
    expect(statusCalls).toBe(1);
    expect(createCalls).toBe(0);

    const [oldVm] = await sql<{ status: string }[]>`
      select status from cloud_vms
      where provider_vm_id = 'provider-vm-provider-creating-old'
    `;
    expect(oldVm?.status).toBe("running");
  });

  dbTest("keeps active limit enforcement when every Freestyle row is still running", async () => {
    if (!sql) throw new Error("test database not initialized");
    await sql`truncate cloud_vm_billing_grants, cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;
    await sql`
      insert into cloud_vms (user_id, billing_team_id, billing_plan_id, provider, provider_vm_id, image_id, status)
      values ('user-workflow-provider-running-old', 'team-workflow-provider-running', 'free', 'freestyle', 'provider-vm-provider-running-old', 'snapshot-test', 'running')
    `;

    let createCalls = 0;
    let statusCalls = 0;
    const provider: VmProviderGatewayShape = {
      create: () =>
        Effect.sync(() => {
          createCalls += 1;
          throw new Error("provider create should not be called");
        }),
      destroy: () => Effect.void,
      exec: () => Effect.succeed({ exitCode: 0, stdout: "", stderr: "" }),
      openAttach: () => Effect.fail(new Error("unused") as never),
      openSSH: () => Effect.fail(new Error("unused") as never),
      revokeSSHIdentity: () => Effect.void,
      getStatus: () =>
        Effect.sync(() => {
          statusCalls += 1;
          return "running" as const;
        }),
    };

    const error = await Effect.runPromise(
      createVm({
        userId: "user-workflow-provider-running-new",
        billingCustomerType: "team",
        billingTeamId: "team-workflow-provider-running",
        billingPlanId: "free",
        maxActiveVms: 1,
        provider: "freestyle",
        image: "snapshot-test",
        idempotencyKey: "provider-running-new",
      }).pipe(
        Effect.flip,
        Effect.provide(providerLayer(provider)),
      ),
    );

    expect(error).toBeInstanceOf(VmLimitExceededError);
    expect(statusCalls).toBe(1);
    expect(createCalls).toBe(0);
  });

  dbTest("does not overwrite a VM destroyed during provider status refresh", async () => {
    if (!sql) throw new Error("test database not initialized");
    const testSql = sql;
    await sql`truncate cloud_vm_billing_grants, cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;
    await sql`
      insert into cloud_vms (user_id, billing_team_id, billing_plan_id, provider, provider_vm_id, image_id, status)
      values ('user-workflow-provider-destroy-race-old', 'team-workflow-provider-destroy-race', 'free', 'freestyle', 'provider-vm-provider-destroy-race-old', 'snapshot-test', 'running')
    `;

    let createCalls = 0;
    let statusCalls = 0;
    const provider: VmProviderGatewayShape = {
      create: () =>
        Effect.sync(() => {
          createCalls += 1;
          return {
            provider: "freestyle" as const,
            providerVmId: "provider-vm-provider-destroy-race-new",
            status: "running" as const,
            image: "snapshot-test",
            createdAt: Date.now(),
          };
        }),
      destroy: () => Effect.void,
      exec: () => Effect.succeed({ exitCode: 0, stdout: "", stderr: "" }),
      openAttach: () => Effect.fail(new Error("unused") as never),
      openSSH: () => Effect.fail(new Error("unused") as never),
      revokeSSHIdentity: () => Effect.void,
      getStatus: () =>
        Effect.promise(async () => {
          statusCalls += 1;
          await testSql`
            update cloud_vms
            set status = 'destroyed', destroyed_at = now(), updated_at = now()
            where provider_vm_id = 'provider-vm-provider-destroy-race-old'
          `;
          return "paused" as const;
        }),
    };

    const created = await Effect.runPromise(
      createVm({
        userId: "user-workflow-provider-destroy-race-new",
        billingCustomerType: "team",
        billingTeamId: "team-workflow-provider-destroy-race",
        billingPlanId: "free",
        maxActiveVms: 1,
        provider: "freestyle",
        image: "snapshot-test",
        idempotencyKey: "provider-destroy-race-new",
      }).pipe(Effect.provide(providerLayer(provider))),
    );

    expect(created.providerVmId).toBe("provider-vm-provider-destroy-race-new");
    expect(statusCalls).toBe(1);
    expect(createCalls).toBe(1);

    const [oldVm] = await sql<{ status: string; destroyedAt: Date | null }[]>`
      select status, destroyed_at as "destroyedAt" from cloud_vms
      where provider_vm_id = 'provider-vm-provider-destroy-race-old'
    `;
    expect(oldVm?.status).toBe("destroyed");
    expect(oldVm?.destroyedAt).toBeInstanceOf(Date);
  });

  dbTest("returns in-progress for concurrent same-key creates before active limit checks", async () => {
    if (!sql) throw new Error("test database not initialized");
    const testSql = sql;
    await sql`truncate cloud_vm_billing_grants, cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;

    let createCalls = 0;
    const provider: VmProviderGatewayShape = {
      create: () =>
        Effect.sync(() => {
          createCalls += 1;
          return {
            provider: "e2b" as const,
            providerVmId: "provider-vm-concurrent-idem",
            status: "running" as const,
            image: "cmuxd-ws:test",
            createdAt: Date.now(),
          };
        }),
      destroy: () => Effect.void,
      exec: () => Effect.succeed({ exitCode: 0, stdout: "", stderr: "" }),
      openAttach: () => Effect.fail(new Error("unused") as never),
      openSSH: () => Effect.fail(new Error("unused") as never),
      revokeSSHIdentity: () => Effect.void,
    };
    const layer = providerLayer(provider);
    const input = {
      userId: "user-workflow-concurrent-idem",
      billingCustomerType: "team" as const,
      billingTeamId: "team-workflow-concurrent-idem",
      billingPlanId: "free",
      maxActiveVms: 1,
      provider: "e2b" as const,
      image: "cmuxd-ws:test",
      idempotencyKey: "concurrent-idem-1",
    };
    const locker = postgres(databaseURL(), { max: 1 });
    let retry: Promise<unknown> | null = null;
    try {
      await locker.begin(async (tx) => {
        await tx`select pg_advisory_xact_lock(hashtextextended(${input.billingTeamId}, 0))`;
        await tx`
          insert into cloud_vms (
            user_id,
            billing_team_id,
            billing_plan_id,
            provider,
            image_id,
            status,
            idempotency_key
          )
          values (
            ${input.userId},
            ${input.billingTeamId},
            ${input.billingPlanId},
            ${input.provider},
            ${input.image},
            'provisioning',
            ${input.idempotencyKey}
          )
        `;
        retry = Effect.runPromise(
          createVm(input).pipe(
            Effect.flip,
            Effect.provide(layer),
          ),
        );
        await waitForBlockedAdvisoryLock(testSql, input.billingTeamId);
      });
    } finally {
      await locker.end();
    }
    const secondError = await retry;

    expect(secondError).toBeInstanceOf(VmCreateInProgressError);
    expect(createCalls).toBe(0);

    const [{ vmCount }] = await sql<{ vmCount: string }[]>`
      select count(*)::text as "vmCount" from cloud_vms
      where user_id = 'user-workflow-concurrent-idem'
    `;
    expect(vmCount).toBe("1");
  });

  dbTest("allows a new create after destroy releases the active team slot", async () => {
    if (!sql) throw new Error("test database not initialized");
    await sql`truncate cloud_vm_billing_grants, cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;
    await sql`
      insert into cloud_vms (user_id, billing_team_id, billing_plan_id, provider, provider_vm_id, image_id, status)
      values ('user-workflow-reuse-slot', 'team-workflow-reuse-slot', 'free', 'e2b', 'provider-vm-reuse-old', 'cmuxd-ws:test', 'running')
    `;

    let createCalls = 0;
    let destroyCalls = 0;
    const provider: VmProviderGatewayShape = {
      create: () =>
        Effect.sync(() => {
          createCalls += 1;
          return {
            provider: "e2b" as const,
            providerVmId: "provider-vm-reuse-new",
            status: "running" as const,
            image: "cmuxd-ws:test",
            createdAt: Date.now(),
          };
        }),
      destroy: () =>
        Effect.sync(() => {
          destroyCalls += 1;
        }),
      exec: () => Effect.succeed({ exitCode: 0, stdout: "", stderr: "" }),
      openAttach: () => Effect.fail(new Error("unused") as never),
      openSSH: () => Effect.fail(new Error("unused") as never),
      revokeSSHIdentity: () => Effect.void,
    };
    const layer = providerLayer(provider);

    await Effect.runPromise(
      destroyVm({ userId: "user-workflow-reuse-slot", providerVmId: "provider-vm-reuse-old" }).pipe(
        Effect.provide(layer),
      ),
    );
    const created = await Effect.runPromise(
      createVm({
        userId: "user-workflow-reuse-slot",
        billingCustomerType: "team",
        billingTeamId: "team-workflow-reuse-slot",
        billingPlanId: "free",
        maxActiveVms: 1,
        provider: "e2b",
        image: "cmuxd-ws:test",
        idempotencyKey: "reuse-slot-new",
      }).pipe(Effect.provide(layer)),
    );

    expect(created.providerVmId).toBe("provider-vm-reuse-new");
    expect(destroyCalls).toBe(1);
    expect(createCalls).toBe(1);

    const [{ runningCount }] = await sql<{ runningCount: string }[]>`
      select count(*)::text as "runningCount"
      from cloud_vms
      where billing_team_id = 'team-workflow-reuse-slot' and status = 'running'
    `;
    expect(runningCount).toBe("1");
  });

  dbTest("reserves Stack Auth credits only once per new idempotency key", async () => {
    if (!sql) throw new Error("test database not initialized");
    await sql`truncate cloud_vm_billing_grants, cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;

    let createCalls = 0;
    const provider: VmProviderGatewayShape = {
      create: () =>
        Effect.sync(() => {
          createCalls += 1;
          return {
            provider: "freestyle" as const,
            providerVmId: "provider-vm-credit-idem",
            status: "running" as const,
            image: "snapshot-credit",
            createdAt: Date.now(),
          };
        }),
      destroy: () => Effect.void,
      exec: () => Effect.succeed({ exitCode: 0, stdout: "", stderr: "" }),
      openAttach: () => Effect.fail(new Error("unused") as never),
      openSSH: () => Effect.fail(new Error("unused") as never),
      revokeSSHIdentity: () => Effect.void,
    };

    let reserveCalls = 0;
    const billing: VmBillingGatewayShape = {
      ...noOpVmBillingGateway(),
      reserveCreate: () =>
        Effect.sync(() => {
          reserveCalls += 1;
          return {
            kind: "stack_item" as const,
            itemId: "cmux-vm-create-credit",
            customerType: "team" as const,
            customerId: "team-workflow-credit-idem",
            amount: 1,
          };
        }),
      refundCreate: () => Effect.void,
    };

    const program = createVm({
      userId: "user-workflow-credit-idem",
      billingCustomerType: "team",
      billingTeamId: "team-workflow-credit-idem",
      billingPlanId: "free",
      maxActiveVms: 1,
      provider: "freestyle",
      image: "snapshot-credit",
      idempotencyKey: "credit-idem-1",
    });
    const layer = providerLayer(provider, billing);

    const first = await Effect.runPromise(program.pipe(Effect.provide(layer)));
    const second = await Effect.runPromise(program.pipe(Effect.provide(layer)));

    expect(first).toEqual(second);
    expect(createCalls).toBe(1);
    expect(reserveCalls).toBe(1);

    const usageEvents = await sql<{ eventType: string }[]>`
      select event_type as "eventType" from cloud_vm_usage_events
      where user_id = 'user-workflow-credit-idem'
      order by created_at, event_type
    `;
    expect(usageEvents.map((event) => event.eventType)).toContain("vm.create.credit.reserved");
  });

  dbTest("grants initial free-plan Stack Auth credits once per billing team", async () => {
    if (!sql) throw new Error("test database not initialized");
    await sql`truncate cloud_vm_billing_grants, cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;

    let createCalls = 0;
    const provider: VmProviderGatewayShape = {
      create: () =>
        Effect.sync(() => {
          createCalls += 1;
          return {
            provider: "e2b" as const,
            providerVmId: `provider-vm-credit-grant-${createCalls}`,
            status: "running" as const,
            image: "cmuxd-ws:credit-grant",
            createdAt: Date.now(),
          };
        }),
      destroy: () => Effect.void,
      exec: () => Effect.succeed({ exitCode: 0, stdout: "", stderr: "" }),
      openAttach: () => Effect.fail(new Error("unused") as never),
      openSSH: () => Effect.fail(new Error("unused") as never),
      revokeSSHIdentity: () => Effect.void,
    };

    let grantCalls = 0;
    let reserveCalls = 0;
    const billing: VmBillingGatewayShape = {
      ...noOpVmBillingGateway(),
      resolveInitialCreateCreditGrant: () => ({
        kind: "stack_item" as const,
        itemId: "cmux-vm-create-credit",
        customerType: "team" as const,
        customerId: "team-workflow-credit-grant",
        amount: 20,
        reason: FREE_INITIAL_CREATE_CREDITS_REASON,
      }),
      applyCreateCreditGrant: () =>
        Effect.sync(() => {
          grantCalls += 1;
        }),
      reserveCreate: () =>
        Effect.sync(() => {
          reserveCalls += 1;
          return {
            kind: "stack_item" as const,
            itemId: "cmux-vm-create-credit",
            customerType: "team" as const,
            customerId: "team-workflow-credit-grant",
            amount: 1,
          };
        }),
    };

    const layer = providerLayer(provider, billing);
    for (const idempotencyKey of ["credit-grant-1", "credit-grant-2"]) {
      await Effect.runPromise(
        createVm({
          userId: "user-workflow-credit-grant",
          billingCustomerType: "team",
          billingTeamId: "team-workflow-credit-grant",
          billingPlanId: "free",
          maxActiveVms: 10,
          provider: "e2b",
          image: "cmuxd-ws:credit-grant",
          idempotencyKey,
        }).pipe(Effect.provide(layer)),
      );
    }

    expect(createCalls).toBe(2);
    expect(grantCalls).toBe(1);
    expect(reserveCalls).toBe(2);

    const [grantRow] = await sql<{ total: number; applied: number }[]>`
      select count(*)::int as total, count(applied_at)::int as applied
      from cloud_vm_billing_grants
      where billing_customer_id = 'team-workflow-credit-grant'
        and item_id = 'cmux-vm-create-credit'
    `;
    expect(grantRow).toEqual({ total: 1, applied: 1 });

    const [grantEvents] = await sql<{ total: number }[]>`
      select count(*)::int as total
      from cloud_vm_usage_events
      where billing_team_id = 'team-workflow-credit-grant'
        and event_type = 'vm.create.credit.granted'
    `;
    expect(grantEvents?.total).toBe(1);
  });

  dbTest("does not call the provider when Stack Auth credits are insufficient", async () => {
    if (!sql) throw new Error("test database not initialized");
    await sql`truncate cloud_vm_billing_grants, cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;

    let createCalls = 0;
    const provider: VmProviderGatewayShape = {
      create: () =>
        Effect.sync(() => {
          createCalls += 1;
          throw new Error("provider should not be called");
        }),
      destroy: () => Effect.void,
      exec: () => Effect.succeed({ exitCode: 0, stdout: "", stderr: "" }),
      openAttach: () => Effect.fail(new Error("unused") as never),
      openSSH: () => Effect.fail(new Error("unused") as never),
      revokeSSHIdentity: () => Effect.void,
    };
    const billing: VmBillingGatewayShape = {
      ...noOpVmBillingGateway(),
      reserveCreate: () => Effect.fail(new VmCreateCreditsInsufficientError({
        itemId: "cmux-vm-create-credit",
        billingCustomerId: "team-workflow-credit-empty",
        amount: 1,
      })),
      refundCreate: () => Effect.void,
    };

    const error = await Effect.runPromise(
      createVm({
        userId: "user-workflow-credit-empty",
        billingCustomerType: "team",
        billingTeamId: "team-workflow-credit-empty",
        billingPlanId: "free",
        maxActiveVms: 1,
        provider: "freestyle",
        image: "snapshot-credit-empty",
        idempotencyKey: "credit-empty-1",
      }).pipe(
        Effect.flip,
        Effect.provide(providerLayer(provider, billing)),
      ),
    );

    expect(error).toBeInstanceOf(VmCreateCreditsInsufficientError);
    expect(createCalls).toBe(0);

    const [failedVm] = await sql<{
      status: string;
      failureCode: string | null;
      providerVmId: string | null;
    }[]>`
      select status, failure_code as "failureCode", provider_vm_id as "providerVmId"
      from cloud_vms
      where user_id = 'user-workflow-credit-empty'
    `;
    expect(failedVm).toMatchObject({
      status: "failed",
      failureCode: "billing_reserve_failed",
      providerVmId: null,
    });

    const usageEvents = await sql<{ eventType: string }[]>`
      select event_type as "eventType" from cloud_vm_usage_events
      where user_id = 'user-workflow-credit-empty'
    `;
    expect(usageEvents.map((event) => event.eventType)).toContain("vm.create.billing_failed");

    const [active] = await sql<{ total: number }[]>`
      select count(*)::int as total from cloud_vms
      where billing_team_id = 'team-workflow-credit-empty'
        and status in ('provisioning', 'running', 'paused')
    `;
    expect(active?.total).toBe(0);

    const recoveryProvider: VmProviderGatewayShape = {
      create: () => Effect.succeed({
        provider: "freestyle" as const,
        providerVmId: "provider-vm-credit-recovered",
        status: "running" as const,
        image: "snapshot-credit-recovered",
        createdAt: Date.now(),
      }),
      destroy: () => Effect.void,
      exec: () => Effect.succeed({ exitCode: 0, stdout: "", stderr: "" }),
      openAttach: () => Effect.fail(new Error("unused") as never),
      openSSH: () => Effect.fail(new Error("unused") as never),
      revokeSSHIdentity: () => Effect.void,
    };

    const recovered = await Effect.runPromise(
      createVm({
        userId: "user-workflow-credit-empty",
        billingCustomerType: "team",
        billingTeamId: "team-workflow-credit-empty",
        billingPlanId: "free",
        maxActiveVms: 1,
        provider: "freestyle",
        image: "snapshot-credit-recovered",
        idempotencyKey: "credit-empty-2",
      }).pipe(Effect.provide(providerLayer(recoveryProvider))),
    );

    expect(recovered.providerVmId).toBe("provider-vm-credit-recovered");
  });

  dbTest("refunds a reserved Stack Auth credit when provider create fails", async () => {
    if (!sql) throw new Error("test database not initialized");
    await sql`truncate cloud_vm_billing_grants, cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;

    const provider: VmProviderGatewayShape = {
      create: () =>
        Effect.fail(new VmProviderOperationError({
          provider: "freestyle",
          operation: "create",
          cause: new Error("provider unavailable"),
        })),
      destroy: () => Effect.void,
      exec: () => Effect.succeed({ exitCode: 0, stdout: "", stderr: "" }),
      openAttach: () => Effect.fail(new Error("unused") as never),
      openSSH: () => Effect.fail(new Error("unused") as never),
      revokeSSHIdentity: () => Effect.void,
    };
    let refundCalls = 0;
    const billing: VmBillingGatewayShape = {
      ...noOpVmBillingGateway(),
      reserveCreate: () => Effect.succeed({
        kind: "stack_item" as const,
        itemId: "cmux-vm-create-credit",
        customerType: "team" as const,
        customerId: "team-workflow-credit-refund",
        amount: 1,
      }),
      refundCreate: () =>
        Effect.sync(() => {
          refundCalls += 1;
        }),
    };

    await expect(
      Effect.runPromise(
        createVm({
          userId: "user-workflow-credit-refund",
          billingCustomerType: "team",
          billingTeamId: "team-workflow-credit-refund",
          billingPlanId: "free",
          maxActiveVms: 1,
          provider: "freestyle",
          image: "snapshot-credit-refund",
          idempotencyKey: "credit-refund-1",
        }).pipe(Effect.provide(providerLayer(provider, billing))),
      ),
    ).rejects.toThrow();

    expect(refundCalls).toBe(1);
    const usageEvents = await sql<{ eventType: string }[]>`
      select event_type as "eventType" from cloud_vm_usage_events
      where user_id = 'user-workflow-credit-refund'
      order by created_at, event_type
    `;
    expect(usageEvents.map((event) => event.eventType).sort()).toEqual([
      "vm.create.credit.refunded",
      "vm.create.credit.reserved",
      "vm.create.failed",
      "vm.create.requested",
    ]);
  });

  dbTest("does not attach another user's VM", async () => {
    if (!sql) throw new Error("test database not initialized");
    await sql`truncate cloud_vm_billing_grants, cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;
    await sql`
      insert into cloud_vms (user_id, billing_team_id, billing_plan_id, provider, provider_vm_id, image_id, status)
      values ('user-workflow-owner', 'team-workflow-owner', 'free', 'freestyle', 'provider-vm-private-1', 'snapshot-test', 'running')
    `;

    let attachCalls = 0;
    const provider: VmProviderGatewayShape = {
      create: () => Effect.fail(new Error("unused") as never),
      destroy: () => Effect.void,
      exec: () => Effect.succeed({ exitCode: 0, stdout: "", stderr: "" }),
      openAttach: () =>
        Effect.sync(() => {
          attachCalls += 1;
          return {
            transport: "websocket" as const,
            url: "wss://example.invalid/pty",
            headers: {},
            token: "pty-token",
            sessionId: "pty-session",
            expiresAtUnix: Math.floor(Date.now() / 1000) + 300,
          };
        }),
      openSSH: () => Effect.fail(new Error("unused") as never),
      revokeSSHIdentity: () => Effect.void,
    };

    const error = await Effect.runPromise(
      openAttachEndpoint({
        userId: "user-workflow-attacker",
        providerVmId: "provider-vm-private-1",
      }).pipe(
        Effect.flip,
        Effect.provide(providerLayer(provider)),
      ),
    );
    expect(error).toBeInstanceOf(VmNotFoundError);
    expect(attachCalls).toBe(0);
  });

  dbTest("does not destroy, exec, or mint SSH for another user's VM", async () => {
    if (!sql) throw new Error("test database not initialized");
    await sql`truncate cloud_vm_billing_grants, cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;
    await sql`
      insert into cloud_vms (user_id, billing_team_id, billing_plan_id, provider, provider_vm_id, image_id, status)
      values ('user-workflow-owner', 'team-workflow-owner', 'free', 'freestyle', 'provider-vm-private-2', 'snapshot-test', 'running')
    `;

    let destroyCalls = 0;
    let execCalls = 0;
    let sshCalls = 0;
    const provider: VmProviderGatewayShape = {
      create: () => Effect.fail(new Error("unused") as never),
      destroy: () => Effect.sync(() => {
        destroyCalls += 1;
      }),
      exec: () => Effect.sync(() => {
        execCalls += 1;
        return { exitCode: 0, stdout: "", stderr: "" };
      }),
      openAttach: () => Effect.fail(new Error("unused") as never),
      openSSH: () => Effect.sync(() => {
        sshCalls += 1;
        return {
          transport: "ssh" as const,
          host: "vm-ssh.freestyle.sh",
          port: 22,
          username: "provider-vm-private-2+cmux",
          publicKeyFingerprint: null,
          credential: { kind: "password" as const, value: "token" },
          identityHandle: "identity",
        };
      }),
      revokeSSHIdentity: () => Effect.void,
    };
    const layer = providerLayer(provider);

    const destroyError = await Effect.runPromise(
      destroyVm({ userId: "user-workflow-attacker", providerVmId: "provider-vm-private-2" }).pipe(
        Effect.flip,
        Effect.provide(layer),
      ),
    );
    const execError = await Effect.runPromise(
      execVm({
        userId: "user-workflow-attacker",
        providerVmId: "provider-vm-private-2",
        command: "true",
        timeoutMs: 1000,
      }).pipe(Effect.flip, Effect.provide(layer)),
    );
    const sshError = await Effect.runPromise(
      openSshEndpoint({ userId: "user-workflow-attacker", providerVmId: "provider-vm-private-2" }).pipe(
        Effect.flip,
        Effect.provide(layer),
      ),
    );

    expect(destroyError).toBeInstanceOf(VmNotFoundError);
    expect(execError).toBeInstanceOf(VmNotFoundError);
    expect(sshError).toBeInstanceOf(VmNotFoundError);
    expect(destroyCalls).toBe(0);
    expect(execCalls).toBe(0);
    expect(sshCalls).toBe(0);
  });

  dbTest("records repeated attach RPC leases idempotently when provider returns a stable daemon token", async () => {
    if (!sql) throw new Error("test database not initialized");
    await sql`truncate cloud_vm_billing_grants, cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;
    const [vm] = await sql<{ id: string }[]>`
      insert into cloud_vms (user_id, provider, provider_vm_id, image_id, status)
      values ('user-workflow-attach', 'freestyle', 'provider-vm-attach-1', 'snapshot-test', 'running')
      returning id
    `;

    let attachCount = 0;
    const provider: VmProviderGatewayShape = {
      create: () => Effect.fail(new Error("unused") as never),
      destroy: () => Effect.void,
      exec: () => Effect.succeed({ exitCode: 0, stdout: "", stderr: "" }),
      openAttach: () =>
        Effect.sync(() => {
          attachCount += 1;
          return {
            transport: "websocket" as const,
            url: "wss://example.invalid/pty",
            headers: {},
            token: `pty-token-${attachCount}`,
            sessionId: `pty-session-${attachCount}`,
            expiresAtUnix: Math.floor(Date.now() / 1000) + 300,
            daemon: {
              url: "wss://example.invalid/rpc",
              headers: {},
              token: "stable-rpc-token",
              sessionId: "stable-rpc-session",
              expiresAtUnix: Math.floor(Date.now() / 1000) + 600,
            },
          };
        }),
      openSSH: () => Effect.fail(new Error("unused") as never),
      revokeSSHIdentity: () => Effect.void,
    };
    const layer = providerLayer(provider);

    await Effect.runPromise(
      openAttachEndpoint({ userId: "user-workflow-attach", providerVmId: "provider-vm-attach-1" }).pipe(
        Effect.provide(layer),
      ),
    );
    await Effect.runPromise(
      openAttachEndpoint({ userId: "user-workflow-attach", providerVmId: "provider-vm-attach-1" }).pipe(
        Effect.provide(layer),
      ),
    );

    const leases = await sql<{ kind: string; sessionId: string | null }[]>`
      select kind, session_id as "sessionId"
      from cloud_vm_leases
      where vm_id = ${vm.id}
      order by kind, session_id
    `;
    expect(leases).toEqual([
      { kind: "pty", sessionId: "pty-session-1" },
      { kind: "pty", sessionId: "pty-session-2" },
      { kind: "rpc", sessionId: "stable-rpc-session" },
    ]);
  });
});

function testCloudVmRow(overrides: Partial<CloudVmRow> = {}): CloudVmRow {
  const now = new Date();
  return {
    id: "00000000-0000-4000-8000-000000000001",
    userId: "user-workflow-usage-events",
    billingTeamId: "team-workflow-usage-events",
    billingPlanId: "free",
    provider: "freestyle",
    providerVmId: null,
    imageId: "snapshot-test",
    imageVersion: null,
    status: "provisioning",
    idempotencyKey: "usage-events",
    createdAt: now,
    updatedAt: now,
    destroyedAt: null,
    failureCode: null,
    failureMessage: null,
    ...overrides,
  };
}

function testWorkflowRepo(input: {
  readonly vm: CloudVmRow;
  readonly usageEvents?: RecordedUsageEvent[];
  readonly leases?: RecordedLease[];
  readonly observedStatuses?: ObservedStatusUpdate[];
  readonly markProviderObservedStatus?: (
    update: ObservedStatusUpdate,
  ) => Effect.Effect<boolean, VmDatabaseError>;
}): VmRepositoryShape {
  return {
    listUserVms: () => Effect.succeed([]),
    claimBillingGrant: () => Effect.succeed({ kind: "already_claimed" }),
    markBillingGrantApplied: () => Effect.void,
    deleteBillingGrant: () => Effect.void,
    beginCreate: () => unusedDatabaseEffect("beginCreate"),
    activeLimitCandidates: () => Effect.succeed([]),
    markProviderObservedStatus: (update) =>
      input.markProviderObservedStatus
        ? input.markProviderObservedStatus(update)
        : Effect.sync(() => {
          input.observedStatuses?.push(update);
          return true;
        }),
    markCreateRunning: () => unusedDatabaseEffect("markCreateRunning"),
    markCreateFailed: () => Effect.void,
    findUserVm: ({ userId, providerVmId }) =>
      Effect.succeed(
        input.vm.userId === userId && input.vm.providerVmId === providerVmId
          ? input.vm
          : null,
      ),
    markDestroyed: () => Effect.void,
    recordLease: (lease) =>
      Effect.sync(() => {
        input.leases?.push(lease);
      }),
    activeIdentityLeases: () => Effect.succeed([]),
    markLeasesRevoked: () => Effect.void,
    recordUsageEvent: (event) =>
      Effect.sync(() => {
        input.usageEvents?.push(event);
      }),
    recordUsageEvents: (events) =>
      Effect.sync(() => {
        input.usageEvents?.push(...events);
      }),
  };
}

function unusedProviderGateway(): VmProviderGatewayShape {
  return {
    create: () => unusedProviderEffect("create"),
    destroy: () => Effect.void,
    exec: () => unusedProviderEffect("exec"),
    openAttach: () => unusedProviderEffect("openAttach"),
    openSSH: () => unusedProviderEffect("openSSH"),
    revokeSSHIdentity: () => Effect.void,
  };
}

function unusedDatabaseEffect<A>(operation: string): Effect.Effect<A, VmDatabaseError> {
  return Effect.fail(new VmDatabaseError({
    operation,
    cause: new Error(`${operation} should not be called`),
  }));
}

function unusedProviderEffect<A>(operation: string): Effect.Effect<A, VmProviderOperationError> {
  return Effect.fail(providerOperationError(operation, `${operation} should not be called`));
}

function providerOperationError(operation: string, message: string): VmProviderOperationError {
  return new VmProviderOperationError({
    provider: "freestyle",
    operation,
    cause: new Error(message),
  });
}

function testVmHandle(overrides: Partial<VMHandle> = {}): VMHandle {
  return {
    provider: "freestyle",
    providerVmId: "provider-vm-test",
    status: "running",
    image: "snapshot-test",
    createdAt: Date.now(),
    ...overrides,
  };
}

function testAttachEndpoint(): AttachEndpoint {
  return {
    transport: "websocket",
    url: "wss://example.invalid/pty",
    headers: {},
    token: "pty-token",
    sessionId: "pty-session",
    expiresAtUnix: Math.floor(Date.now() / 1000) + 300,
  };
}

function testSshEndpoint(): SSHEndpoint {
  return {
    transport: "ssh",
    host: "vm-ssh.freestyle.sh",
    port: 22,
    username: "provider-vm-ssh-resume+cmux",
    publicKeyFingerprint: null,
    credential: { kind: "password", value: "token" },
    identityHandle: "identity-ssh-resume",
  };
}

async function waitForBlockedAdvisoryLock(sql: Sql, billingTeamId: string): Promise<void> {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    const [{ blocked }] = await sql<{ blocked: string }[]>`
      with target as (
        select
          (((hashtextextended(${billingTeamId}, 0) >> 32) & 4294967295)::bigint)::oid as classid,
          ((hashtextextended(${billingTeamId}, 0) & 4294967295)::bigint)::oid as objid
      )
      select count(*)::text as "blocked"
      from pg_locks l
      join target t on l.classid = t.classid and l.objid = t.objid
      where l.locktype = 'advisory'
        and l.objsubid = 1
        and not l.granted
    `;
    if (Number(blocked) > 0) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error("timed out waiting for blocked advisory lock");
}
