import { describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import { VmRepository, type CloudVmRow, type VmRepositoryShape } from "../services/vms/repository";
import { runVmRoute } from "../services/vms/routeWorkflow";
import { listUserVms } from "../services/vms/workflows";

// Production 2026-11-25: GET /api/vm hung for the route's full 960 s
// maxDuration on a quarter of function instances while their database pool
// was wedged; the Mac app, the CLI and `cmux vm env set` had long given up.
// The list's database read is bounded: past its budget the route answers the
// retryable 503 and drops this instance's database client so the next
// request reconnects instead of queueing behind the dead pool.

function listRoute(listUserVms: VmRepositoryShape["listUserVms"], budgetMs: number) {
  const resets: string[] = [];
  const repo = { listUserVms } as unknown as VmRepositoryShape;
  const run = runVmRoute(listUserVms("owner", null).pipe(Effect.provide(Layer.succeed(VmRepository, repo))), {
    locale: "en",
    databaseDeadline: { operation: "listUserVms", budgetMs, onDeadline: () => resets.push("reset") },
  });
  return { run, resets };
}

describe("GET /api/vm database deadline", () => {
  test("a list read that never answers is a retryable 503 at the budget and resets the database client", async () => {
    const startedAtMs = performance.now();
    const { run, resets } = listRoute(() => Effect.never, 50);
    const result = await run;
    expect(performance.now() - startedAtMs).toBeLessThan(2_000);
    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(result.response.status).toBe(503);
    expect(result.response.headers.get("Retry-After")).not.toBeNull();
    const payload = await result.response.json() as Record<string, unknown>;
    expect(payload).toMatchObject({ error: "vm_cloud_state_unavailable", retryable: true });
    expect(resets).toEqual(["reset"]);
  });

  test("a list read that answers in time is unaffected and keeps the database client", async () => {
    const row = {
      id: "row-1", userId: "owner", ownerTeamId: "owner", billingTeamId: null,
      provider: "freestyle", providerVmId: "vm-1", status: "running", providerMetadata: {},
      createdAt: new Date(0), updatedAt: new Date(0),
    } as unknown as CloudVmRow;
    const { run, resets } = listRoute(() => Effect.succeed([row]), 5_000);
    const result = await run;
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.value.map((entry) => entry.providerVmId)).toEqual(["vm-1"]);
    expect(resets).toEqual([]);
  });
});
