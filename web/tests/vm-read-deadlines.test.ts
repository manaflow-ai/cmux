import { afterEach, beforeEach, describe, expect, spyOn, test } from "bun:test";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import { VmBillingGateway, noOpVmBillingGateway } from "../services/vms/billingGateway";
import { isOperatorFaultVmError } from "../services/vms/observability";
import { VmProviderGatewayLive } from "../services/vms/providerGateway";
import { VmRepository, type CloudVmRow, type VmRepositoryShape } from "../services/vms/repository";
import { VM_READ_ROUTE_DEADLINES, vmReadAnswerBudgetMs } from "../services/vms/routeDeadline";
import { runVmRoute } from "../services/vms/routeWorkflow";
import { getVmStats } from "../services/vms/workflows";

// Production 2026-10-11: GET /api/vm/[id]/stats waited on a hung provider
// read long after the Mac client (30 s) gave up. Stage A of the reland after
// #19467: a read route bounds only its provider reads, inline. At the budget
// the read is interrupted, its requests' AbortSignal fires, and the route
// answers 504 vm_provider_timeout. Nothing is forked or continues.
//
// These tests drive the real path: runVmRoute, the workflow, the Effect
// gateway (providerEffect), the Freestyle driver and SDK. Only the HTTP
// transport (global fetch) and the owned-row repository are fixtures.

type FetchRecord = { path: string; signal: AbortSignal | undefined };
let fetches: FetchRecord[] = [];
let hangingVmIds = new Set<string>();
const savedEnv = { key: process.env.FREESTYLE_API_KEY, url: process.env.FREESTYLE_API_URL };

beforeEach(() => {
  fetches = [];
  hangingVmIds = new Set();
  process.env.FREESTYLE_API_KEY = "test-only";
  process.env.FREESTYLE_API_URL = "https://freestyle.test";
  spyOn(globalThis, "fetch").mockImplementation(((input: RequestInfo | URL, init?: RequestInit) => {
    const path = new URL(input instanceof Request ? input.url : String(input)).pathname;
    const signal = init?.signal ?? undefined;
    fetches.push({ path, signal });
    const vmId = path.split("/").pop() ?? "";
    if (!hangingVmIds.has(vmId)) {
      return Promise.resolve(Response.json({ id: vmId, state: "running", resources: { cpu: 2, memory: 4096, storage: 16384 } }));
    }
    // A hung provider: it answers only by failing when its request is aborted.
    return new Promise<Response>((_resolve, reject) => {
      if (signal?.aborted) reject(signal.reason);
      signal?.addEventListener("abort", () => reject(signal.reason), { once: true });
    });
  }) as typeof fetch);
});

afterEach(() => {
  (globalThis.fetch as unknown as { mockRestore?: () => void }).mockRestore?.();
  process.env.FREESTYLE_API_KEY = savedEnv.key;
  process.env.FREESTYLE_API_URL = savedEnv.url;
});

function statsRoute(providerVmId: string, remainingBudgetMs: number) {
  const row = {
    id: `row-${providerVmId}`, userId: "owner", ownerTeamId: "owner", billingTeamId: null,
    provider: "freestyle", providerVmId, status: "running", providerMetadata: {},
  } as CloudVmRow;
  const repo = {
    findUserVm: (input: { providerVmId: string }) => Effect.succeed(input.providerVmId === providerVmId ? row : null),
  } as unknown as VmRepositoryShape;
  const layer = Layer.mergeAll(Layer.succeed(VmRepository, repo), VmProviderGatewayLive, Layer.succeed(VmBillingGateway, noOpVmBillingGateway()));
  const elapsedMs = VM_READ_ROUTE_DEADLINES.stats.clientTimeoutMs - 5_000 - remainingBudgetMs;
  return runVmRoute(getVmStats({ userId: "owner", providerVmId }).pipe(Effect.provide(layer)), {
    locale: "en",
    readDeadline: { operation: "stats", elapsedMs },
  });
}

describe("VM read deadlines through the real route path", () => {
  test("a hung provider read is aborted at the deadline and answers 504 vm_provider_timeout", async () => {
    hangingVmIds.add("vm-hung");
    const run = await statsRoute("vm-hung", 150);
    expect(run.ok).toBe(false);
    if (run.ok) return;
    expect(run.response.status).toBe(504);
    const payload = await run.response.json() as Record<string, unknown>;
    expect(payload).toMatchObject({ error: "vm_provider_timeout", retryable: true });
    // The request the read made was aborted when the route answered: no fetch outlives the 504.
    const request = fetches.find((entry) => entry.path === "/v5/vms/vm-hung");
    expect(request?.signal?.aborted).toBe(true);
  });

  test("a read that answers in time is unaffected and its request is never aborted", async () => {
    const run = await statsRoute("vm-ok", 5_000);
    expect(run.ok).toBe(true);
    if (!run.ok) return;
    expect(run.value).toMatchObject({ state: "unknown", health: "unknown", cpus: 2 });
    expect(fetches.find((entry) => entry.path === "/v5/vms/vm-ok")?.signal?.aborted).toBe(false);
  });

  // Many requests at once through the same path: hung reads time out on their
  // own budgets, the others answer their own machine, and no abort crosses
  // from one request to another.
  test("60 concurrent reads, 20 hung, share nothing", async () => {
    const ids = Array.from({ length: 60 }, (_, index) => `vm-${index}`);
    for (const [index, id] of ids.entries()) if (index % 3 === 0) hangingVmIds.add(id);
    const runs = await Promise.all(ids.map((id) => statsRoute(id, 300)));
    for (const [index, run] of runs.entries()) {
      const id = ids[index]!;
      const request = fetches.find((entry) => entry.path === `/v5/vms/${id}`);
      if (hangingVmIds.has(id)) {
        expect(run.ok).toBe(false);
        if (!run.ok) expect(run.response.status).toBe(504);
        expect(request?.signal?.aborted).toBe(true);
      } else {
        expect(run.ok).toBe(true);
        expect(request?.signal?.aborted).toBe(false);
      }
    }
  });
});

describe("VM read deadline budget", () => {
  test("every read leaves its client 5 s, measured from the request's start", () => {
    expect(vmReadAnswerBudgetMs("stats", 0)).toBe(25_000);
    expect(vmReadAnswerBudgetMs("stats", 4_000)).toBe(21_000);
    expect(vmReadAnswerBudgetMs("getVm", 0)).toBe(55_000);
  });

  test("the answer never goes past the client's limit, even when auth spent the budget", () => {
    expect(vmReadAnswerBudgetMs("stats", 30_000)).toBe(0);
  });

  test("a provider timeout is not a per-request operator fault", () => {
    expect(isOperatorFaultVmError({ error: "vm_provider_timeout", status: 504 })).toBe(false);
  });
});
