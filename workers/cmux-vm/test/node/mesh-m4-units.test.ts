/**
 * Mesh M4 units: the positive-only membership cache over a fake Stack API
 * (cx-0op.7), the Svix webhook signature check (G1), and the mesh writer lock
 * in the tenant ledger.
 */
import { Effect, Redacted } from "effect";
import { describe, expect, it } from "vitest";
import { makeStackTeamMembership } from "../../src/auth/credentials.ts";
import { makeMemoryMembershipCache, MEMBERSHIP_POSITIVE_TTL_MS } from "../../src/auth/membership-cache.ts";
import { signWebhookContent, verifyWebhookSignature } from "../../src/auth/webhook-signature.ts";
import { StoreError } from "../../src/db/sql.ts";
import { TenantId, UserId } from "../../src/lib/ids.ts";
import { memoryLedgerStorage, TenantLedger } from "../../src/limits/ledger.ts";

const T = TenantId.make("team_alpha");
const U = UserId.make("user_ada");

const stack = (initiallyMember: boolean) => {
  const state: { member: boolean; calls: number; during: (() => void) | null } = { member: initiallyMember, calls: 0, during: null };
  const fetch = async (_request: Request): Promise<Response> => {
    state.calls += 1;
    const answer = state.member;
    state.during?.();
    return Response.json({ items: answer ? [{ id: T }] : [] });
  };
  return { state, fetch };
};

const membership = (fake: ReturnType<typeof stack>, clock: { now: number }) => {
  const cache = makeMemoryMembershipCache();
  const service = makeStackTeamMembership({
    apiUrl: "https://stack.test",
    projectId: "project-test",
    serverKey: Redacted.make("server-key"),
    cache: cache.service,
    fetch: fake.fetch,
    now: () => clock.now,
  });
  return { cache, isMember: () => Effect.runPromise(service.isMember(T, U)) };
};

describe("membership cache: positive answers only, 60 s", () => {
  it("caches 'member' for 60 s, then asks Stack again", async () => {
    const fake = stack(true);
    const clock = { now: 1_000_000 };
    const m = membership(fake, clock);
    expect(await m.isMember()).toBe(true);
    expect(await m.isMember()).toBe(true);
    expect(fake.state.calls).toBe(1);
    clock.now += MEMBERSHIP_POSITIVE_TTL_MS - 1;
    expect(await m.isMember()).toBe(true);
    expect(fake.state.calls).toBe(1);
    clock.now += 2;
    expect(await m.isMember()).toBe(true);
    expect(fake.state.calls).toBe(2);
  });

  it("never caches 'not a member'", async () => {
    const fake = stack(false);
    const m = membership(fake, { now: 1_000_000 });
    expect(await m.isMember()).toBe(false);
    expect(await m.isMember()).toBe(false);
    expect(fake.state.calls).toBe(2);
    fake.state.member = true;
    expect(await m.isMember()).toBe(true);
  });

  it("a revocation drops the cached answer at once", async () => {
    const fake = stack(true);
    const clock = { now: 1_000_000 };
    const m = membership(fake, clock);
    expect(await m.isMember()).toBe(true);
    fake.state.member = false;
    clock.now += 1;
    await Effect.runPromise(m.cache.service.revoke(T, U, new Date(clock.now)));
    expect(await m.isMember()).toBe(false);
    expect(fake.state.calls).toBe(2);
  });

  it("a 'member' answer whose request was in flight when the revocation landed is not cached", async () => {
    const fake = stack(true);
    const clock = { now: 1_000_000 };
    const m = membership(fake, clock);
    fake.state.during = () => {
      // The webhook revokes while Stack's (now stale) "member" answer travels back.
      clock.now += 5;
      Effect.runSync(m.cache.service.revoke(T, U, new Date(clock.now)));
      fake.state.member = false;
      fake.state.during = null;
    };
    expect(await m.isMember()).toBe(true);
    expect(await m.isMember()).toBe(false);
    expect(fake.state.calls).toBe(2);
  });

  it("a cache that fails is skipped: Stack answers", async () => {
    const fake = stack(false);
    const down = new StoreError({ operation: "membership", cause: null });
    const failing = { fresh: () => Effect.fail(down), rememberMember: () => Effect.fail(down), revoke: () => Effect.fail(down), revokeUser: () => Effect.fail(down) };
    const service = makeStackTeamMembership({
      apiUrl: "https://stack.test",
      projectId: "project-test",
      serverKey: Redacted.make("server-key"),
      cache: failing,
      fetch: fake.fetch,
    });
    expect(await Effect.runPromise(service.isMember(T, U))).toBe(false);
    fake.state.member = true;
    expect(await Effect.runPromise(service.isMember(T, U))).toBe(true);
  });
});

describe("Stack (Svix) webhook signature", () => {
  const secret = Redacted.make(`whsec_${btoa("unit-test-webhook-secret-32-byte")}`);
  const body = JSON.stringify({ type: "team_membership.deleted", data: { team_id: "t", user_id: "u" } });
  const headers = async (id: string, timestamp: number, override?: string) =>
    new Headers({
      "svix-id": id,
      "svix-timestamp": String(timestamp),
      "svix-signature": override ?? `v1,${await signWebhookContent(secret, `${id}.${timestamp}.${body}`)}`,
    });
  const now = 1_790_000_000_000;

  it("accepts a valid signature, also among several", async () => {
    expect(await verifyWebhookSignature(secret, await headers("msg_1", now / 1000), body, now)).toEqual({ ok: true, messageId: "msg_1" });
    const good = `v1,${await signWebhookContent(secret, `msg_1.${now / 1000}.${body}`)}`;
    expect((await verifyWebhookSignature(secret, await headers("msg_1", now / 1000, `v1,AAAA ${good}`), body, now)).ok).toBe(true);
  });

  it("refuses a changed body, another id, a stale timestamp and missing headers", async () => {
    const h = await headers("msg_1", now / 1000);
    expect(await verifyWebhookSignature(secret, h, body.replace('"u"', '"x"'), now)).toEqual({ ok: false, reason: "signature" });
    h.set("svix-id", "msg_2");
    expect(await verifyWebhookSignature(secret, h, body, now)).toEqual({ ok: false, reason: "signature" });
    expect(await verifyWebhookSignature(secret, await headers("msg_1", now / 1000 - 301), body, now)).toEqual({ ok: false, reason: "stale" });
    expect(await verifyWebhookSignature(secret, new Headers(), body, now)).toEqual({ ok: false, reason: "headers" });
  });
});

describe("mesh writer lock (tenant ledger)", () => {
  it("one holder at a time; released or expired locks are free", async () => {
    const ledger = new TenantLedger(memoryLedgerStorage());
    expect(await ledger.lock("mesh-writer:m", "a", 1000, 0)).toBe(true);
    expect(await ledger.lock("mesh-writer:m", "b", 1000, 10)).toBe(false);
    expect(await ledger.lock("mesh-writer:other", "b", 1000, 10)).toBe(true);
    await ledger.unlock("mesh-writer:m", "b");
    expect(await ledger.lock("mesh-writer:m", "b", 1000, 20)).toBe(false);
    await ledger.unlock("mesh-writer:m", "a");
    expect(await ledger.lock("mesh-writer:m", "b", 1000, 30)).toBe(true);
    expect(await ledger.lock("mesh-writer:m", "c", 1000, 1031)).toBe(true);
  });
});
