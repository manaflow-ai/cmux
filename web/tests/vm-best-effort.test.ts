import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import { bestEffort } from "../services/vms/bestEffort";
import { noOpVmBillingGateway, VmBillingGateway } from "../services/vms/billingGateway";
import { VmDatabaseError } from "../services/vms/errors";
import { VmProviderGateway, type VmProviderGatewayShape } from "../services/vms/providerGateway";
import { VmRepository, type CloudVmRow, type VmRepositoryShape } from "../services/vms/repository";
import { execVm, runVmWorkflowExit } from "../services/vms/workflows";

const originalConsoleError = console.error;
let consoleErrorCalls: unknown[][] = [];

beforeEach(() => {
  consoleErrorCalls = [];
  console.error = ((...args: unknown[]) => {
    consoleErrorCalls.push(args);
  }) as typeof console.error;
});

afterEach(() => {
  console.error = originalConsoleError;
});

function reportedOperations(): string[] {
  return consoleErrorCalls
    .filter((call) => call[0] === "cmux.observability.error")
    .map((call) => {
      const context = call[1] as { bestEffortOperation?: string };
      return context?.bestEffortOperation ?? "";
    });
}

describe("bestEffort", () => {
  test("swallows the failure but reports it with the operation label", async () => {
    const failure = new VmDatabaseError({
      operation: "recordUsageEvent",
      cause: new Error("db down"),
    });
    const result = await Effect.runPromise(
      bestEffort("usage_event.test", { vmId: "vm-1", provider: "freestyle" })(
        Effect.fail(failure),
      ),
    );
    expect(result).toBeUndefined();
    expect(reportedOperations()).toContain("usage_event.test");
  });

  test("stays silent on success", async () => {
    await Effect.runPromise(bestEffort("usage_event.test")(Effect.succeed("done")));
    expect(reportedOperations()).toHaveLength(0);
  });
});

describe("execVm usage event (representative bestEffort site)", () => {
  test("a failing usage-event write is reported and does not fail the exec", async () => {
    const vmRow = {
      id: "row-1",
      userId: "user-1",
      billingTeamId: null,
      billingPlanId: "free",
      provider: "freestyle",
      providerVmId: "vm-provider-1",
      imageId: "image-1",
      imageVersion: null,
      status: "running",
      displayName: null,
      providerMetadata: null,
      createdAt: new Date(),
      updatedAt: new Date(),
    } as unknown as CloudVmRow;
    const repo = {
      findUserVm: () => Effect.succeed(vmRow),
      recordUsageEvent: () =>
        Effect.fail(
          new VmDatabaseError({ operation: "recordUsageEvent", cause: new Error("db down") }),
        ),
    } as unknown as VmRepositoryShape;
    const providers = {
      exec: () => Effect.succeed({ exitCode: 0, stdout: "ok", stderr: "" }),
    } as unknown as VmProviderGatewayShape;
    const layer = Layer.mergeAll(
      Layer.succeed(VmRepository, repo),
      Layer.succeed(VmProviderGateway, providers),
      Layer.succeed(VmBillingGateway, noOpVmBillingGateway()),
    );

    const result = await Effect.runPromise(
      execVm({
        userId: "user-1",
        providerVmId: "vm-provider-1",
        command: "pwd",
        timeoutMs: 1000,
      }).pipe(Effect.provide(layer)),
    );

    expect(result.exitCode).toBe(0);
    expect(reportedOperations()).toContain("usage_event.vm.exec");
  });

  test("sanity: runVmWorkflowExit type accepts the same program shape", async () => {
    // Keeps the adapter and the workflow programs aligned at the type level;
    // runtime coverage for the adapter lives in vm-workflow-exit.test.ts.
    const result = await runVmWorkflowExit(Effect.succeed("aligned"));
    expect(result).toEqual({ ok: true, value: "aligned" });
  });
});
