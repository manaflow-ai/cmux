import { describe, expect, setDefaultTimeout, test } from "bun:test";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import {
  appleRenewalMayBeMissing,
  decideVmPlanLapse,
  isLiveStripeSubscription,
  makeStripeSaysStillLive,
  makeVmOwnerPlanLookup,
  type VmOwnerPlanFacts,
  type VmPlanSources,
} from "../services/vms/planLapse";
import { enforceVmPlanLapse, VM_PLAN_LAPSE_MAX_PAUSES_PER_RUN, VM_PLAN_LAPSE_TRIP_MIN_OWNERS } from "../services/vms/planLapseJob";
import { VmNotFoundError } from "../services/vms/errors";
import { VmProviderGateway } from "../services/vms/providerGateway";
import { VmRepository, type CloudVmRow } from "../services/vms/repository";

// The first test pays for loading the VM and billing modules on a busy machine.
setDefaultTimeout(30_000);

const none: VmOwnerPlanFacts = {
  isCompanyAccount: false,
  adminGrantPlanId: null,
  hasLiveStripeSubscription: false,
  hasPausedStripeSubscription: false,
  hasApplePlan: false,
  hasPaidTeam: false,
  isSharedTeamMachine: false,
  metadataPlanIsPaid: false,
  teamIds: [],
};

describe("decideVmPlanLapse", () => {
  test("every kind of paid or granted access keeps the machine", () => {
    expect(decideVmPlanLapse({ ...none, isCompanyAccount: true })).toBe("keep_company");
    expect(decideVmPlanLapse({ ...none, adminGrantPlanId: "founders" })).toBe("keep_admin_grant");
    expect(decideVmPlanLapse({ ...none, hasLiveStripeSubscription: true })).toBe("keep_stripe");
    expect(decideVmPlanLapse({ ...none, hasApplePlan: true })).toBe("keep_apple");
    expect(decideVmPlanLapse({ ...none, hasPaidTeam: true })).toBe("keep_team");
    expect(decideVmPlanLapse({ ...none, isSharedTeamMachine: true })).toBe("keep_shared_team_machine");
    expect(decideVmPlanLapse({ ...none, metadataPlanIsPaid: true })).toBe("keep_unbacked_metadata_plan");
  });
  test("no evidence is a lapse, and an unpaid override is not a grant", () => {
    expect(decideVmPlanLapse(none)).toBe("lapsed");
    expect(decideVmPlanLapse({ ...none, adminGrantPlanId: "free" })).toBe("lapsed");
  });
  test("a paused subscription lapses even though its plan mirror still says pro", () => {
    expect(decideVmPlanLapse({ ...none, hasPausedStripeSubscription: true, metadataPlanIsPaid: true })).toBe("lapsed");
  });
  test("a grant or a second live subscription outranks a paused one", () => {
    expect(decideVmPlanLapse({ ...none, hasPausedStripeSubscription: true, adminGrantPlanId: "pro" })).toBe("keep_admin_grant");
    expect(decideVmPlanLapse({ ...none, hasPausedStripeSubscription: true, hasLiveStripeSubscription: true })).toBe("keep_stripe");
  });
});

describe("isLiveStripeSubscription", () => {
  test("active with pause_collection is not live; past_due still is", () => {
    expect(isLiveStripeSubscription("active", { pause_collection: { behavior: "keep_as_draft" } })).toBe(false);
    expect(isLiveStripeSubscription("active", { pause_collection: null })).toBe(true);
    expect(isLiveStripeSubscription("past_due", {})).toBe(true);
    expect(isLiveStripeSubscription("canceled", {})).toBe(false);
  });
});

const vm = (id: string, userId: string) =>
  ({ id, userId, providerVmId: `fs-${id}`, provider: "freestyle", billingTeamId: null, billingPlanId: "pro", imageId: "i", providerMetadata: {} }) as unknown as CloudVmRow;

function harness() {
  const paused: string[] = [];
  const patches: unknown[] = [];
  let pauseFails = false;
  const layer = Layer.mergeAll(
    Layer.succeed(VmRepository, {
      mergeProviderMetadata: (input: { patch: unknown }) => Effect.sync(() => { patches.push(input.patch); }),
      markProviderObservedStatus: () => Effect.succeed(true),
      recordUsageEvent: () => Effect.void,
    } as never),
    Layer.succeed(VmProviderGateway, {
      pause: (_provider: string, id: string) => pauseFails
        ? Effect.fail(new VmNotFoundError({ vmId: id }))
        : Effect.sync(() => { paused.push(id); }),
    } as never),
  );
  return { paused, patches, layer, failPauses: () => { pauseFails = true; } };
}

const enforce = { CMUX_VM_PLAN_LAPSE_PAUSE: "enforce" };
const stillPausable = async () => true;

describe("enforceVmPlanLapse", () => {
  test("a dry run reports the lapsed machine and pauses nothing", async () => {
    const { paused, layer } = harness();
    const result = await Effect.runPromise(enforceVmPlanLapse({
      env: {}, listRunning: async () => [vm("a", "u1")], lookup: async () => none, confirmStillLive: async () => false,
    }).pipe(Effect.provide(layer)));
    expect(result.mode).toBe("dry_run");
    expect(result.lapsed.map((row) => row.providerVmId)).toEqual(["fs-a"]);
    expect(paused).toEqual([]);
  });
  test("enforced, it pauses only the lapsed owner's machines", async () => {
    const { paused, layer } = harness();
    const result = await Effect.runPromise(enforceVmPlanLapse({
      env: enforce,
      stillPausable,
      listRunning: async () => [vm("a", "lapsed"), vm("b", "payer"), vm("c", "lapsed")],
      lookup: async ({ userId }) => userId === "lapsed" ? none : { ...none, hasLiveStripeSubscription: true },
      confirmStillLive: async () => false,
    }).pipe(Effect.provide(layer)));
    expect(paused.sort()).toEqual(["fs-a", "fs-c"]);
    expect(result.paused).toBe(2);
    expect(result.decisions).toEqual({ lapsed: 2, keep_stripe: 1 });
  });
  test("an unknown owner, a failed lookup, or Stripe saying live never pauses", async () => {
    const { paused, layer } = harness();
    const result = await Effect.runPromise(enforceVmPlanLapse({
      env: enforce,
      stillPausable,
      listRunning: async () => [vm("a", "gone"), vm("b", "boom"), vm("c", "stale"), vm("d", "stripe-down")],
      lookup: async ({ userId }) => {
        if (userId === "gone") return null;
        if (userId === "boom") throw new Error("stack unavailable");
        return none;
      },
      confirmStillLive: async (userId) => {
        if (userId === "stripe-down") throw new Error("stripe unavailable");
        return true;
      },
    }).pipe(Effect.provide(layer)));
    expect(paused).toEqual([]);
    expect(result.unknown).toBe(3);
    expect(result.lookupErrors).toBe(2);
    expect(result.stripeMirrorStale).toBe(1);
  });
  test("one run pauses at most the cap and reports the rest", async () => {
    const { paused, layer } = harness();
    const count = VM_PLAN_LAPSE_MAX_PAUSES_PER_RUN + 3;
    const result = await Effect.runPromise(enforceVmPlanLapse({
      env: enforce,
      stillPausable,
      listRunning: async () => Array.from({ length: count }, (_, index) => vm(`m${index}`, "lapsed")),
      lookup: async () => none,
      confirmStillLive: async () => false,
    }).pipe(Effect.provide(layer)));
    expect(paused.length).toBe(VM_PLAN_LAPSE_MAX_PAUSES_PER_RUN);
    expect(result.deferred).toBe(3);
  });
  test("too many lapsed owners looks like a bad read: nothing pauses unless an operator allows it", async () => {
    const machines = Array.from({ length: VM_PLAN_LAPSE_TRIP_MIN_OWNERS + 1 }, (_, index) => vm(`m${index}`, `u${index}`));
    const run = async (env: Record<string, string>) => {
      const { paused, layer } = harness();
      const result = await Effect.runPromise(enforceVmPlanLapse({
        env, stillPausable, listRunning: async () => machines, lookup: async () => none, confirmStillLive: async () => false,
      }).pipe(Effect.provide(layer)));
      return { result, paused };
    };
    const tripped = await run(enforce);
    expect(tripped.result.tripped).toBe(true);
    expect(tripped.paused).toEqual([]);
    const allowed = await run({ ...enforce, CMUX_VM_PLAN_LAPSE_ALLOW_LARGE_RUN: "1" });
    expect(allowed.result.tripped).toBe(false);
    expect(allowed.paused.length).toBe(machines.length);
  });
  test("a machine that changed since the decision is left alone", async () => {
    const { paused, layer } = harness();
    const result = await Effect.runPromise(enforceVmPlanLapse({
      env: enforce, stillPausable: async () => false, listRunning: async () => [vm("a", "u1")], lookup: async () => none, confirmStillLive: async () => false,
    }).pipe(Effect.provide(layer)));
    expect(paused).toEqual([]);
    expect(result.skipped).toBe(1);
  });
  test("past the time budget it stops looking up and stops pausing", async () => {
    const { paused, layer } = harness();
    let clock = 0;
    const result = await Effect.runPromise(enforceVmPlanLapse({
      env: enforce, stillPausable, now: () => clock, listRunning: async () => [vm("a", "u1")],
      lookup: async () => { clock = 1_000_000; return none; },
      confirmStillLive: async () => false,
    }).pipe(Effect.provide(layer)));
    expect(paused).toEqual([]);
    expect(result.deferred).toBe(1);
  });
  test("a lookup that times out and answers late neither decides nor pauses", async () => {
    const { paused, layer } = harness();
    const result = await Effect.runPromise(enforceVmPlanLapse({
      env: enforce, stillPausable, lookupTimeoutMs: 5, listRunning: async () => [vm("a", "slow")],
      lookup: async () => { await new Promise((resolve) => setTimeout(resolve, 30)); return none; },
      confirmStillLive: async () => false,
    }).pipe(Effect.provide(layer)));
    await new Promise((resolve) => setTimeout(resolve, 50));
    expect(paused).toEqual([]);
    expect(result.lookupErrors).toBe(1);
    expect(result.decisions).toEqual({});
    expect(result.lapsed).toEqual([]);
  });
  test("a provider that never answers fails the pause inside its time limit", async () => {
    const { layer } = harness();
    const hung = Layer.merge(layer, Layer.succeed(VmProviderGateway, { pause: () => Effect.never } as never));
    const result = await Effect.runPromise(enforceVmPlanLapse({
      env: enforce, stillPausable, pauseTimeoutMs: 5, listRunning: async () => [vm("a", "u1")], lookup: async () => none, confirmStillLive: async () => false,
    }).pipe(Effect.provide(hung)));
    expect(result.errors).toBe(1);
    expect(result.paused).toBe(0);
  });
  test("the large-run stop divides by owners that answered, not owners that exist", async () => {
    const { paused, layer } = harness();
    const lapsedUsers = VM_PLAN_LAPSE_TRIP_MIN_OWNERS + 1;
    const machines = Array.from({ length: 100 }, (_, index) => vm(`m${index}`, `u${index}`));
    const result = await Effect.runPromise(enforceVmPlanLapse({
      env: enforce, stillPausable, listRunning: async () => machines, confirmStillLive: async () => false,
      lookup: async ({ userId }) => {
        if (Number(userId.slice(1)) < lapsedUsers) return none;
        throw new Error("stack unavailable");
      },
    }).pipe(Effect.provide(layer)));
    expect(result.tripped).toBe(true);
    expect(paused).toEqual([]);
  });
  test("a failed pause leaves no intent for the minute job to finish", async () => {
    const { paused, patches, layer, failPauses } = harness();
    failPauses();
    const result = await Effect.runPromise(enforceVmPlanLapse({
      env: enforce, stillPausable, listRunning: async () => [vm("a", "u1")], lookup: async () => none, confirmStillLive: async () => false,
    }).pipe(Effect.provide(layer)));
    expect(paused).toEqual([]);
    expect(result.errors).toBe(1);
    expect(patches).toEqual([]);
  });
  test("where free machines are allowed nothing has lapsed", async () => {
    const { paused, layer } = harness();
    const result = await Effect.runPromise(enforceVmPlanLapse({
      env: { ...enforce, CMUX_VM_ALLOW_FREE_PROVISIONING: "1" },
      listRunning: async () => { throw new Error("must not read"); },
    }).pipe(Effect.provide(layer)));
    expect(result.mode).toBe("off_free_provisioning");
    expect(paused).toEqual([]);
  });
});

const sources = (over: Partial<VmPlanSources> = {}): VmPlanSources => ({
  getUser: async () => ({ id: "u1", clientReadOnlyMetadata: {} }) as never,
  listTeams: async () => [],
  getTeam: async () => null,
  personalSubscriptions: async () => [],
  teamSubscriptions: async () => [],
  hasApplePlan: async () => false,
  ...over,
});
const team = (id: string, memberIds: string[], clientReadOnlyMetadata: unknown = {}) =>
  ({ id, clientReadOnlyMetadata, listUsers: async () => memberIds.map((member) => ({ id: member })) });

describe("makeVmOwnerPlanLookup", () => {
  test("a user-billed row does not read its own id as a team", async () => {
    let asked = false;
    const facts = await makeVmOwnerPlanLookup(sources({ getTeam: async () => { asked = true; return null; } }))({ userId: "u1", billingTeamId: "u1" });
    expect(asked).toBe(false);
    expect(decideVmPlanLapse(facts!)).toBe("lapsed");
  });
  test("a machine on a team with another member is shared; a solo team is not; a missing team counts as shared", async () => {
    const lookupWith = (found: ReturnType<typeof team> | null) => makeVmOwnerPlanLookup(sources({ getTeam: async () => found }))({ userId: "u1", billingTeamId: "t1" });
    expect((await lookupWith(team("t1", ["u1", "u2"])))!.isSharedTeamMachine).toBe(true);
    expect((await lookupWith(team("t1", ["u1"])))!.isSharedTeamMachine).toBe(false);
    expect((await lookupWith(null))!.isSharedTeamMachine).toBe(true);
  });
  test("a team's paid metadata or live row is a paid team; a paused row alone is not", async () => {
    const lookupWith = (metadata: unknown, rows: { status: string; raw: unknown }[]) => makeVmOwnerPlanLookup(sources({
      listTeams: async () => [{ id: "t1", clientReadOnlyMetadata: metadata }],
      teamSubscriptions: async () => rows,
    }))({ userId: "u1", billingTeamId: null });
    expect((await lookupWith({ cmuxPlan: "founders" }, []))!.hasPaidTeam).toBe(true);
    expect((await lookupWith({}, [{ status: "active", raw: {} }]))!.hasPaidTeam).toBe(true);
    expect((await lookupWith({}, [{ status: "active", raw: { pause_collection: { behavior: "void" } } }]))!.hasPaidTeam).toBe(false);
  });
  test("an unknown user is null and a failed team list rejects", async () => {
    expect(await makeVmOwnerPlanLookup(sources({ getUser: async () => null }))({ userId: "u1", billingTeamId: null })).toBeNull();
    await expect(makeVmOwnerPlanLookup(sources({ listTeams: async () => { throw new Error("incomplete"); } }))({ userId: "u1", billingTeamId: null })).rejects.toThrow("incomplete");
  });
});

describe("appleRenewalMayBeMissing", () => {
  const now = new Date("2026-11-03T00:00:00Z");
  const expired = (days: number) => new Date(now.getTime() - days * 86_400_000);
  test("set to renew and just expired may be a lost notification; anything else is an expiry", () => {
    expect(appleRenewalMayBeMissing({ status: "expired", expiresAt: expired(1), autoRenewEnabled: true }, now)).toBe(true);
    expect(appleRenewalMayBeMissing({ status: "expired", expiresAt: expired(1), autoRenewEnabled: null }, now)).toBe(true);
    expect(appleRenewalMayBeMissing({ status: "expired", expiresAt: expired(8), autoRenewEnabled: true }, now)).toBe(false);
    expect(appleRenewalMayBeMissing({ status: "expired", expiresAt: expired(1), autoRenewEnabled: false }, now)).toBe(false);
    expect(appleRenewalMayBeMissing({ status: "revoked", expiresAt: expired(1), autoRenewEnabled: true }, now)).toBe(false);
    expect(appleRenewalMayBeMissing({ status: "expired", expiresAt: null, autoRenewEnabled: true }, now)).toBe(false);
  });
});

describe("makeStripeSaysStillLive", () => {
  test("a team customer's live subscription counts, and a paused one does not", async () => {
    const asked: unknown[] = [];
    const check = (subscription: Record<string, unknown>) => makeStripeSaysStillLive({
      customerIds: async (userId, teamIds) => { asked.push([userId, teamIds]); return ["cus_team"]; },
      subscriptions: async () => [subscription as never],
    })("u1", ["t1"]);
    expect(await check({ status: "active" })).toBe(true);
    expect(await check({ status: "active", pause_collection: { behavior: "keep_as_draft" } })).toBe(false);
    expect(asked[0]).toEqual(["u1", ["t1"]]);
  });
});
