import { describe, expect, spyOn, test } from "bun:test";
import { Effect, Layer } from "effect";
import { Freestyle } from "freestyle";
import { VmBillingGateway, noOpVmBillingGateway } from "../services/vms/billingGateway";
import { getProvider } from "../services/vms/drivers";
import { FreestyleProvider } from "../services/vms/drivers/freestyle";
import { VmDatabaseError } from "../services/vms/errors";
import { isOperatorFaultVmError } from "../services/vms/observability";
import { VmProviderGatewayLive } from "../services/vms/providerGateway";
import { VmRepository, type CloudVmRow, type VmRepositoryShape } from "../services/vms/repository";
import { vmWorkflowErrorResponse } from "../services/vms/routeHelpers";
import { getVmStats } from "../services/vms/workflows";

// Real SDK response decoding, driver wrapping, Effect gateway and workflow.
// Only the provider HTTP transport and owned-row repository are fixtures.
async function withStatsFixture(
  reply: () => Response,
  run: (fixture: {
    poll: (userId?: string, teamIds?: readonly string[]) => Promise<{
      tag: string;
      response: Response;
      payload: { error: string; action: string; retryable?: boolean; ui: { title: string; retryable: boolean } };
    }>;
    requests: string[];
    writes: unknown[];
    row: CloudVmRow;
  }) => Promise<void>,
  options: { failObservation?: boolean; team?: boolean } = {},
) {
  const requests: string[] = [];
  const writes: unknown[] = [];
  const row = {
    id: "fixture-row", userId: "fixture-owner", billingTeamId: options.team ? "fixture-team" : null,
    provider: "freestyle", providerVmId: "vm-fixture", providerMetadata: {}, status: "running",
  } as CloudVmRow;
  const client = new Freestyle({
    apiKey: "test-only",
    fetch: (async (input, init) => {
      const path = new URL(String(input)).pathname;
      requests.push(`${init?.method} ${path}`);
      expect(`${init?.method} ${path}`).toBe("GET /v5/vms/vm-fixture");
      return reply();
    }) as typeof fetch,
  });
  const driver = new FreestyleProvider({
    client: () => client,
    resolveDaemonSource: async () => { throw new Error("Stats must not install anything"); },
  });
  const getStats = spyOn(getProvider("freestyle"), "getStats").mockImplementation((id) => driver.getStats(id));
  const repo = new Proxy({
    findUserVm: (input: { userId: string; providerVmId: string }) => Effect.sync(() =>
      input.userId === row.userId && input.providerVmId === row.providerVmId && row.status !== "destroyed" ? row : null),
    markProviderObservedStatus: (input: { id: string; providerVmId: string; status: "destroyed" }) => Effect.suspend(() => {
      writes.push(input);
      if (options.failObservation) return Effect.fail(new VmDatabaseError({ operation: "fixture", cause: new Error("offline") }));
      expect(input).toEqual({ id: row.id, providerVmId: row.providerVmId, status: "destroyed" });
      row.status = input.status;
      return Effect.succeed(true);
    }),
  }, {
    get(target, key) {
      if (key in target) return Reflect.get(target, key);
      throw new Error(`Unexpected repository operation: ${String(key)}`);
    },
  }) as unknown as VmRepositoryShape;
  const layer = Layer.mergeAll(
    Layer.succeed(VmRepository, repo), VmProviderGatewayLive,
    Layer.succeed(VmBillingGateway, noOpVmBillingGateway()),
  );
  try {
    await run({
      row, requests, writes,
      poll: async (userId = row.userId, teamIds = options.team ? ["fixture-team"] : []) => {
        const result = await Effect.runPromise(Effect.either(getVmStats({
          userId, teamIds, providerVmId: row.providerVmId!,
        }).pipe(Effect.provide(layer))));
        expect(result._tag).toBe("Left");
        if (result._tag !== "Left") throw new Error("Expected a fixture failure");
        const response = await vmWorkflowErrorResponse(result.left);
        if (!response) throw new Error("Expected the shared HTTP error contract");
        return { tag: result.left._tag, response, payload: await response.json() };
      },
    });
  } finally {
    getStats.mockRestore();
  }
}

const missing = () => Response.json({ code: "NOT_FOUND", message: "not found: vm vm-fixture" }, { status: 404 });

describe("stats provider missing classification", () => {
  test("typed NOT_FOUND becomes a terminal 404 across repeated polling, retaining the row", async () => {
    await withStatsFixture(missing, async ({ poll, row, requests, writes }) => {
      for (let attempt = 0; attempt < 3; attempt += 1) {
        const { tag, response, payload } = await poll();
        expect(tag).toBe("VmNotFoundError");
        expect(response.status).toBe(404);
        expect(response.headers.get("retry-after")).toBeNull();
        expect(payload.error).toBe("vm_not_found");
        expect(payload.ui).toMatchObject({ title: "Cloud VM not found", retryable: false });
        expect(payload.action).not.toMatch(/temporarily|retry|try again/i);
        expect(isOperatorFaultVmError({ error: payload.error, status: response.status })).toBe(false);
      }
      expect(requests).toHaveLength(1);
      expect(writes).toHaveLength(1);
      expect(row).toMatchObject({ id: "fixture-row", providerVmId: "vm-fixture", status: "destroyed" });
    });
  });

  test("a failed observation write never changes missing VM guidance to a retryable outage", async () => {
    await withStatsFixture(missing, async ({ poll, row, requests }) => {
      for (let attempt = 0; attempt < 3; attempt += 1) {
        const { response, payload } = await poll();
        expect(response.status).toBe(404);
        expect(payload.ui.retryable).toBe(false);
      }
      expect(requests).toHaveLength(3);
      expect(row.status).toBe("running");
    }, { failObservation: true });
  });

  test.each([false, true])("ownership is checked before the provider (team=%s)", async (team) => {
    await withStatsFixture(missing, async ({ poll, requests, writes }) => {
      const { response, payload } = await (team ? poll("fixture-owner", []) : poll("another-user"));
      expect(response.status).toBe(404);
      expect(payload.error).toBe("vm_not_found");
      expect(JSON.stringify(payload)).not.toMatch(/fixture-owner|fixture-team|fixture-row|freestyle/);
      expect(requests).toHaveLength(0);
      expect(writes).toHaveLength(0);
    }, { team });
  });

  test.each([
    { name: "typed upstream 502", reply: () => Response.json({ code: "INTERNAL", message: "upstream unavailable" }, { status: 502 }) },
    { name: "typed upstream 502 mentioning a missing VM", reply: () => Response.json({ code: "INTERNAL", message: "VM not found in upstream cache; retry" }, { status: 502 }) },
    { name: "transport failure", reply: () => { throw new TypeError("fetch failed"); } },
  ])("$name remains retryable and cannot mark the machine destroyed", async ({ reply }) => {
    await withStatsFixture(reply, async ({ poll, row, writes }) => {
      const { tag, response, payload } = await poll();
      expect(tag).toBe("VmProviderOperationError");
      expect(response.status).toBe(502);
      expect(payload).toMatchObject({ error: "vm_cloud_service_unavailable", retryable: true, ui: { retryable: true } });
      expect(isOperatorFaultVmError({ error: payload.error, status: response.status })).toBe(true);
      expect(writes).toHaveLength(0);
      expect(row.status).toBe("running");
    });
  });
});
