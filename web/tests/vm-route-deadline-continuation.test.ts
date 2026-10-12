import { afterEach, beforeEach, describe, expect, mock, spyOn, test } from "bun:test";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";

// The #19405 stats stalls (production 2026-10-11) were never reproduced, and
// stage A (#19511) showed the inline read path is safe on its own. The
// remaining suspect is the background continuation of a mutation. This test
// runs the real after() continuation of real mutation workflows (hung at the
// provider) while many stage-A reads run through the real route path, and
// requires every read to reach its provider call and answer.
//
// next/server's after() is the only module replaced: it runs the callback the
// way Next does after a response, concurrently with later requests.
const afterCallbacks: Array<Promise<unknown>> = [];
mock.module("next/server", () => ({
  after: (callback: () => Promise<unknown>) => { afterCallbacks.push(callback()); },
}));

const { VmBillingGateway, noOpVmBillingGateway } = await import("../services/vms/billingGateway");
const { VmProviderGatewayLive } = await import("../services/vms/providerGateway");
const { VmRepository } = await import("../services/vms/repository");
const { VM_READ_ROUTE_DEADLINES, backgroundContinuations, withVmAnswerDeadline } = await import("../services/vms/routeDeadline");
const { runVmRoute } = await import("../services/vms/routeWorkflow");
const { getVmStats, pauseVm } = await import("../services/vms/workflows");
type CloudVmRow = import("../services/vms/repository").CloudVmRow;
type VmRepositoryShape = import("../services/vms/repository").VmRepositoryShape;

type FetchRecord = { method: string; path: string; signal: AbortSignal | undefined };
let fetches: FetchRecord[] = [];
const savedEnv = { key: process.env.FREESTYLE_API_KEY, url: process.env.FREESTYLE_API_URL };

beforeEach(() => {
  fetches = [];
  afterCallbacks.length = 0;
  process.env.FREESTYLE_API_KEY = "test-only";
  process.env.FREESTYLE_API_URL = "https://freestyle.test";
  spyOn(globalThis, "fetch").mockImplementation(((input: RequestInfo | URL, init?: RequestInit) => {
    const path = new URL(input instanceof Request ? input.url : String(input)).pathname;
    const method = init?.method ?? "GET";
    const signal = init?.signal ?? undefined;
    fetches.push({ method, path, signal });
    if (method === "POST" && path.endsWith("/pause")) {
      // A hung provider pause: it fails only when its request is aborted.
      return new Promise<Response>((_resolve, reject) => {
        signal?.addEventListener("abort", () => reject(signal.reason), { once: true });
      });
    }
    const vmId = path.split("/").pop() ?? "";
    return Promise.resolve(Response.json({ id: vmId, state: "running", resources: { cpu: 2, memory: 4096, storage: 16384 } }));
  }) as typeof fetch);
});

afterEach(() => {
  (globalThis.fetch as unknown as { mockRestore?: () => void }).mockRestore?.();
  process.env.FREESTYLE_API_KEY = savedEnv.key;
  process.env.FREESTYLE_API_URL = savedEnv.url;
});

function layerFor(providerVmId: string) {
  const row = {
    id: `row-${providerVmId}`, userId: "owner", ownerTeamId: "owner", billingTeamId: null, billingPlanId: "pro",
    provider: "freestyle", providerVmId, status: "running", providerMetadata: {},
  } as CloudVmRow;
  const repo = {
    findUserVm: (input: { providerVmId: string }) => Effect.succeed(input.providerVmId === providerVmId ? row : null),
    markProviderObservedStatus: () => Effect.succeed(true),
    recordUsageEvent: () => Effect.void,
  } as unknown as VmRepositoryShape;
  return Layer.mergeAll(Layer.succeed(VmRepository, repo), VmProviderGatewayLive, Layer.succeed(VmBillingGateway, noOpVmBillingGateway()));
}

describe("mutation continuations and live reads", () => {
  test("reads reach their provider call and answer while 20 hung pauses continue after their responses", async () => {
    // 20 pauses answer "in progress" and keep running through the real after().
    const pauses = await Promise.all(Array.from({ length: 20 }, (_, index) => {
      const id = `vm-pause-${index}`;
      return Effect.runPromise(Effect.either(withVmAnswerDeadline(
        pauseVm({ userId: "owner", providerVmId: id }).pipe(Effect.provide(layerFor(id))),
        { answerWithinMs: 50, onDeadline: () => Effect.fail("in progress" as const), continueForMs: 2_000, label: "/api/vm/[id]/pause" },
      )));
    }));
    expect(pauses.every((answer) => answer._tag === "Left" && answer.left === "in progress")).toBe(true);
    expect(afterCallbacks).toHaveLength(20);
    expect(backgroundContinuations.running).toBe(20);

    // 60 stats reads through the real route path while those continue.
    const ids = Array.from({ length: 60 }, (_, index) => `vm-read-${index}`);
    const elapsedMs = VM_READ_ROUTE_DEADLINES.stats.clientTimeoutMs - 5_000 - 5_000;
    const reads = await Promise.all(ids.map((id) => runVmRoute(
      getVmStats({ userId: "owner", providerVmId: id }).pipe(Effect.provide(layerFor(id))),
      { locale: "en", readDeadline: { operation: "stats", elapsedMs } },
    )));
    for (const [index, read] of reads.entries()) {
      expect(read.ok).toBe(true);
      expect(fetches.some((entry) => entry.method === "GET" && entry.path === `/v5/vms/${ids[index]}`)).toBe(true);
    }
    // The continuations were still running the whole time.
    expect(backgroundContinuations.running).toBe(20);

    // Each continuation ends by its window and gives its slot back.
    await Promise.all(afterCallbacks);
    expect(backgroundContinuations.running).toBe(0);
    const pauseRequests = fetches.filter((entry) => entry.method === "POST" && entry.path.endsWith("/pause"));
    expect(pauseRequests).toHaveLength(20);
  });
});
