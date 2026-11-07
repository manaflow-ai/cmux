import { Deferred, Duration, Effect, Either, Fiber, Layer } from "effect";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { withMeshWriter } from "../../src/handlers/mesh.ts";
import { TenantId } from "../../src/lib/ids.ts";
import { memoryLimitsLayer, TenantLimits, type TenantLimitsService } from "../../src/limits/service.ts";
import { ALL_SCOPES, bearer } from "../support/endpoints.ts";
import { makeHarness } from "../support/harness.ts";

const TEAM = "team_alpha";
const tenant = TenantId.make(TEAM);
const record = (v: unknown): Record<string, unknown> => typeof v === "object" && v !== null ? Object.fromEntries(Object.entries(v)) : {};
const freshLimits = () => Effect.runPromise(Effect.provide(TenantLimits, memoryLimitsLayer()));
const run = <A, E>(limits: TenantLimitsService, effect: Effect.Effect<A, E, TenantLimits>) =>
  Effect.runPromise(effect.pipe(Effect.provide(Layer.succeed(TenantLimits, limits))));

describe("mesh reads under a held writer lock", () => {
  let h: Awaited<ReturnType<typeof makeHarness>>;
  let limits: TenantLimitsService;
  let admin: string, mesh: string, vm: string;
  beforeEach(async () => {
    limits = await freshLimits();
    h = await makeHarness({ limits: Layer.succeed(TenantLimits, limits) });
    admin = await h.addKey(TEAM, ALL_SCOPES);
    const id = record(await (await h.request("/v1/meshes", bearer(admin), { method: "POST", body: {} })).json())["id"];
    if (typeof id !== "string") throw new Error("mesh creation returned no public id");
    mesh = id;
    vm = h.addVm(TEAM).vmId;
    expect((await h.request(`/v1/meshes/${mesh}/vms/${vm}`, bearer(admin), { method: "PUT" })).status).toBe(200);
  });
  afterEach(async () => { await h.dispose(); });

  // A writer whose Worker request was cancelled (the client gave up) never runs its unlock. Reads must not queue behind it:
  // on staging every receiver-policy read waited out the platform's 15 s budget and left its own lease behind.
  const holdStuckWriter = () => run(limits, Effect.flatMap(TenantLimits, (l) => l.lock(tenant, `mesh-writer:${mesh}`, "cancelled-request", 5 * 60_000)));

  it("answers a receiver-policy read without waiting for the writer", async () => {
    expect(await holdStuckWriter()).toBe(true);
    const started = Date.now();
    const response = await h.request(`/v1/meshes/${mesh}/vms/${vm}/receiver-policy`, bearer(admin));
    expect(response.status).toBe(200);
    expect(Date.now() - started).toBeLessThan(5_000);
  }, 30_000);

  it("answers a member read without waiting for the writer", async () => {
    expect(await holdStuckWriter()).toBe(true);
    const started = Date.now();
    const response = await h.request(`/v1/meshes/${mesh}/vms/${vm}`, bearer(admin));
    expect(response.status).toBe(200);
    expect(Date.now() - started).toBeLessThan(5_000);
  }, 30_000);

  it("still makes an ACL apply wait for the writer", async () => {
    expect(await holdStuckWriter()).toBe(true);
    // The apply waits its full 15 s for the lock, then refuses: two reconciles never interleave.
    const response = await h.request(`/v1/meshes/${mesh}/acl`, bearer(admin), { method: "PUT", body: { expectedVersion: 0, rules: [] } });
    expect(response.status).toBe(409);
  }, 30_000);
});

describe("mesh writer lease", () => {
  const MESH = "mesh_lease_test";
  const timing = { leaseMs: 300, renewEveryMs: 100, waitMs: 200 };

  it("frees the lock soon after its holder's request died without unlocking", async () => {
    const limits = await freshLimits();
    // The cancelled request: its effect never ends and its unlock never runs.
    const dead: TenantLimitsService = { ...limits, unlock: () => Effect.void };
    const taken = await run(dead, Effect.gen(function* () {
      const inside = yield* Deferred.make<void>();
      const fiber = yield* Effect.fork(withMeshWriter(tenant, MESH, Deferred.succeed(inside, undefined).pipe(Effect.zipRight(Effect.never)), timing));
      yield* Deferred.await(inside);
      // The Workers runtime drops a cancelled request's pending work: no finalizer, no further renewal.
      yield* Fiber.interrupt(fiber);
      return true;
    }));
    expect(taken).toBe(true);
    await new Promise((resolve) => setTimeout(resolve, timing.leaseMs + 50));
    const next = await run(limits, withMeshWriter(tenant, MESH, Effect.succeed("next writer"), timing).pipe(Effect.either));
    expect(next).toEqual(Either.right("next writer"));
  });

  it("keeps a live holder's lock past one lease, so two writers never interleave", async () => {
    const limits = await freshLimits();
    const outcome = await run(limits, Effect.gen(function* () {
      const inside = yield* Deferred.make<void>();
      const release = yield* Deferred.make<void>();
      const first = yield* Effect.fork(withMeshWriter(tenant, MESH,
        Deferred.succeed(inside, undefined).pipe(Effect.zipRight(Deferred.await(release)), Effect.as("first")), timing));
      yield* Deferred.await(inside);
      // Two leases later the first writer is still running: its renewals keep the lock.
      yield* Effect.sleep(Duration.millis(timing.leaseMs * 2));
      const second = yield* withMeshWriter(tenant, MESH, Effect.succeed("second"), timing).pipe(Effect.either);
      yield* Deferred.succeed(release, undefined);
      const firstResult = yield* Fiber.join(first);
      const after = yield* withMeshWriter(tenant, MESH, Effect.succeed("after"), timing);
      return { second, firstResult, after };
    }));
    expect(Either.isLeft(outcome.second)).toBe(true);
    if (Either.isLeft(outcome.second)) expect(outcome.second.left).toMatchObject({ _tag: "Conflict" });
    expect(outcome.firstResult).toBe("first");
    expect(outcome.after).toBe("after");
  });
});
