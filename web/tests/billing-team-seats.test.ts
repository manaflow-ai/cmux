import { describe, expect, test } from "bun:test";
import type Stripe from "stripe";
import {
  billableSeats,
  reconcileTeamSeats,
  seatDecision,
  type TeamSeatReconcileDependencies,
  type TeamSeatStripeClient,
} from "../services/billing/teamSeats";
import {
  ADMIN_GRANTS,
  ADMIN_ID,
  MEMBER_GRANTS,
  MEMBER_ID,
  MemoryTeamSeatQueue,
  OTHER_TEAM_ID,
  OUTSIDER_ID,
  standardTeam,
  TEAM_ID,
  type FakeStack,
} from "./teams-fixture";

const SUBSCRIPTION_ID = "sub_team_1";
const ITEM_ID = "si_team_1";

describe("seat delta rule", () => {
  test("bills one seat per member and never below one", () => {
    expect(billableSeats(0)).toBe(1);
    expect(billableSeats(4)).toBe(4);
    expect(seatDecision({ planId: "team", hasTeamSubscription: true, memberCount: 3, quantity: 2 }))
      .toEqual({ action: "update", from: 2, to: 3 });
    expect(seatDecision({ planId: "team", hasTeamSubscription: true, memberCount: 1, quantity: 4 }))
      .toEqual({ action: "update", from: 4, to: 1 });
    expect(seatDecision({ planId: "team", hasTeamSubscription: true, memberCount: 0, quantity: 3 }))
      .toEqual({ action: "update", from: 3, to: 1 });
  });

  test("is a no-op when the quantity already matches", () => {
    expect(seatDecision({ planId: "team", hasTeamSubscription: true, memberCount: 3, quantity: 3 }))
      .toEqual({ action: "noop", quantity: 3 });
  });

  test("updates from an unknown quantity", () => {
    expect(seatDecision({ planId: null, hasTeamSubscription: true, memberCount: 2, quantity: null }))
      .toEqual({ action: "update", from: null, to: 2 });
  });

  test("ignores Pro and Max personal teams and teams without a Team subscription", () => {
    expect(seatDecision({ planId: "pro", hasTeamSubscription: true, memberCount: 3, quantity: 1 }))
      .toEqual({ action: "skip", reason: "personal_plan" });
    expect(seatDecision({ planId: "max", hasTeamSubscription: false, memberCount: 3, quantity: null }))
      .toEqual({ action: "skip", reason: "personal_plan" });
    expect(seatDecision({ planId: "free", hasTeamSubscription: false, memberCount: 3, quantity: null }))
      .toEqual({ action: "skip", reason: "no_team_subscription" });
    expect(seatDecision({ planId: null, hasTeamSubscription: false, memberCount: 3, quantity: null }))
      .toEqual({ action: "skip", reason: "no_team_subscription" });
  });
});

class FakeStripe implements TeamSeatStripeClient {
  readonly updates: { subscriptionId: string; itemId: string; quantity: number }[] = [];
  status = "active";
  failUpdate = false;
  constructor(public quantity: number) {}

  private subscription(): Stripe.Subscription {
    return {
      id: SUBSCRIPTION_ID,
      status: this.status,
      metadata: { app: "cmux", stackTeamId: TEAM_ID },
      items: { data: [{ id: ITEM_ID, quantity: this.quantity }] },
    } as unknown as Stripe.Subscription;
  }

  async retrieve(): Promise<Stripe.Subscription> {
    return this.subscription();
  }

  async updateQuantity(subscriptionId: string, itemId: string, quantity: number): Promise<Stripe.Subscription> {
    if (this.failUpdate) throw new Error("stripe down");
    this.updates.push({ subscriptionId, itemId, quantity });
    this.quantity = quantity;
    return this.subscription();
  }
}

function harness(input: { stack?: FakeStack; quantity?: number; rowSeats?: number | null; subscribed?: boolean } = {}) {
  const stack = input.stack ?? standardTeam();
  const queue = new MemoryTeamSeatQueue();
  const stripe = new FakeStripe(input.quantity ?? 2);
  const applied: number[] = [];
  const errors: unknown[] = [];
  const deps: TeamSeatReconcileDependencies = {
    queue,
    stack: stack.app(),
    stripe,
    activeSubscription: async (teamId) =>
      (input.subscribed ?? true) && teamId === TEAM_ID
        ? { id: SUBSCRIPTION_ID, seats: input.rowSeats === undefined ? stripe.quantity : input.rowSeats }
        : null,
    apply: async (subscription) => {
      applied.push(subscription.items.data[0]!.quantity!);
    },
    captureError: (error) => errors.push(error),
  };
  return { stack, queue, stripe, applied, errors, deps };
}

describe("team seat reconciler", () => {
  test("raises the Stripe quantity to the member count after a join", async () => {
    const { stack, queue, stripe, applied, deps } = harness();
    stack.addMember(TEAM_ID, OUTSIDER_ID, MEMBER_GRANTS);
    await queue.markDirty(TEAM_ID);

    const result = await reconcileTeamSeats({}, deps);

    expect(result).toEqual({ checked: 1, updated: 1, skipped: 0, failed: 0, busy: 0 });
    expect(stripe.updates).toEqual([{ subscriptionId: SUBSCRIPTION_ID, itemId: ITEM_ID, quantity: 3 }]);
    expect(applied).toEqual([3]);
    const row = queue.rows.get(TEAM_ID)!;
    expect(row).toMatchObject({ dirtyAt: null, lastMemberCount: 3, lastStripeQuantity: 3, lastError: null });
  });

  test("lowers the quantity after a removal and leaves the row clean", async () => {
    const { stack, queue, stripe, deps } = harness({ quantity: 2 });
    stack.teams.get(TEAM_ID)!.members.delete(MEMBER_ID);
    await queue.markDirty(TEAM_ID);

    await reconcileTeamSeats({}, deps);

    expect(stripe.updates.map((update) => update.quantity)).toEqual([1]);
    expect(queue.rows.get(TEAM_ID)!.dirtyAt).toBeNull();
  });

  test("pending invitations do not cost a seat", async () => {
    const { stack, queue, stripe, deps } = harness({ quantity: 2 });
    stack.addInvitation(TEAM_ID, "one@example.com");
    stack.addInvitation(TEAM_ID, "two@example.com");
    await queue.markDirty(TEAM_ID);

    const result = await reconcileTeamSeats({}, deps);

    expect(result.updated).toBe(0);
    expect(stripe.updates).toEqual([]);
    expect(queue.rows.get(TEAM_ID)!).toMatchObject({ dirtyAt: null, lastMemberCount: 2, lastStripeQuantity: 2 });
  });

  test("is a no-op when our row lags but Stripe already matches", async () => {
    const { stack, queue, stripe, applied, deps } = harness({ quantity: 3, rowSeats: 2 });
    stack.addMember(TEAM_ID, OUTSIDER_ID, MEMBER_GRANTS);
    await queue.markDirty(TEAM_ID);

    const result = await reconcileTeamSeats({}, deps);

    expect(result.updated).toBe(0);
    expect(stripe.updates).toEqual([]);
    expect(applied).toEqual([]);
    expect(queue.rows.get(TEAM_ID)!).toMatchObject({ dirtyAt: null, lastStripeQuantity: 3 });
  });

  test("skips personal-plan and unsubscribed teams but still clears them", async () => {
    const personal = standardTeam();
    personal.teams.get(TEAM_ID)!.metadata = { cmuxPlan: "pro" };
    const paidPersonal = harness({ stack: personal });
    await paidPersonal.queue.markDirty(TEAM_ID);
    expect(await reconcileTeamSeats({}, paidPersonal.deps)).toMatchObject({ skipped: 1, updated: 0 });
    expect(paidPersonal.stripe.updates).toEqual([]);
    expect(paidPersonal.queue.rows.get(TEAM_ID)!.dirtyAt).toBeNull();

    const free = harness({ subscribed: false });
    await free.queue.markDirty(TEAM_ID);
    expect(await reconcileTeamSeats({}, free.deps)).toMatchObject({ skipped: 1, updated: 0 });
    expect(free.stripe.updates).toEqual([]);
    expect(free.queue.rows.get(TEAM_ID)!).toMatchObject({ dirtyAt: null, lastMemberCount: 2 });
  });

  test("a deleted team is cleared without touching Stripe", async () => {
    const { queue, stripe, deps } = harness();
    await queue.markDirty(OTHER_TEAM_ID);
    expect(await reconcileTeamSeats({}, deps)).toMatchObject({ skipped: 1 });
    expect(stripe.updates).toEqual([]);
    expect(queue.rows.get(OTHER_TEAM_ID)!.dirtyAt).toBeNull();
  });

  test("a lapsed subscription is not edited", async () => {
    const { stack, queue, stripe, deps } = harness({ quantity: 2 });
    stripe.status = "canceled";
    stack.addMember(TEAM_ID, OUTSIDER_ID, MEMBER_GRANTS);
    await queue.markDirty(TEAM_ID);
    await reconcileTeamSeats({}, deps);
    expect(stripe.updates).toEqual([]);
    expect(queue.rows.get(TEAM_ID)!.dirtyAt).toBeNull();
  });

  test("a Stripe failure keeps the team dirty and records the error", async () => {
    const { stack, queue, stripe, errors, deps } = harness();
    stripe.failUpdate = true;
    stack.addMember(TEAM_ID, OUTSIDER_ID, MEMBER_GRANTS);
    await queue.markDirty(TEAM_ID);

    const result = await reconcileTeamSeats({}, deps);

    expect(result).toMatchObject({ failed: 1, updated: 0 });
    expect(errors).toHaveLength(1);
    const row = queue.rows.get(TEAM_ID)!;
    expect(row.dirtyAt).not.toBeNull();
    expect(row.lastError).toContain("stripe down");
    expect(row.lastStripeQuantity).toBeNull();
  });

  test("a change during the run keeps the team dirty for the next pass", async () => {
    const { stack, queue, deps } = harness();
    stack.addMember(TEAM_ID, OUTSIDER_ID, MEMBER_GRANTS);
    await queue.markDirty(TEAM_ID);
    const later = new Date(queue.now.getTime() + 1000);
    const remark = { ...deps, stripe: {
      retrieve: async () => {
        queue.now = later;
        await queue.markDirty(TEAM_ID);
        return { id: SUBSCRIPTION_ID, status: "active", items: { data: [{ id: ITEM_ID, quantity: 2 }] } } as unknown as Stripe.Subscription;
      },
      updateQuantity: async (_id: string, _item: string, quantity: number) =>
        ({ id: SUBSCRIPTION_ID, status: "active", items: { data: [{ id: ITEM_ID, quantity }] } }) as unknown as Stripe.Subscription,
    } };

    await reconcileTeamSeats({}, remark);

    expect(queue.rows.get(TEAM_ID)!.dirtyAt?.getTime()).toBe(later.getTime());
  });

  test("a team another worker holds is skipped as busy", async () => {
    const { queue, stripe, deps } = harness();
    await queue.markDirty(TEAM_ID);
    queue.locked.add(TEAM_ID);
    expect(await reconcileTeamSeats({}, deps)).toMatchObject({ busy: 1, updated: 0 });
    expect(stripe.updates).toEqual([]);
    expect(queue.rows.get(TEAM_ID)!.dirtyAt).not.toBeNull();
  });

  test("scopes an inline run to the named team", async () => {
    const { queue, deps } = harness();
    await queue.markDirty(TEAM_ID);
    await queue.markDirty(OTHER_TEAM_ID);
    expect(await reconcileTeamSeats({ teamIds: [OTHER_TEAM_ID] }, deps)).toMatchObject({ checked: 1 });
    expect(queue.rows.get(TEAM_ID)!.dirtyAt).not.toBeNull();
    expect(queue.rows.get(OTHER_TEAM_ID)!.dirtyAt).toBeNull();
  });

  test("admins count as members like everyone else", async () => {
    const { stack, queue, stripe, deps } = harness({ quantity: 1 });
    stack.addMember(TEAM_ID, OUTSIDER_ID, ADMIN_GRANTS);
    await queue.markDirty(TEAM_ID);
    await reconcileTeamSeats({}, deps);
    expect(stripe.updates.map((update) => update.quantity)).toEqual([3]);
    expect(stack.teams.get(TEAM_ID)!.members.has(ADMIN_ID)).toBe(true);
  });
});
