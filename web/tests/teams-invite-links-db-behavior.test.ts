// Database-backed proof of the invite-link claim contract: the in-memory store
// in tests/teams-fixture.ts mirrors these semantics, and this file checks the
// real SQL (atomic claim, max uses under concurrency, expiry, revocation,
// idempotency, release) against Postgres. Gated like the other *-db-behavior tests.

import { afterAll, beforeAll, beforeEach, describe, expect, test } from "bun:test";
import postgres, { type Sql } from "postgres";
import { closeCloudDbForTests } from "../db/client";
import { databaseTeamInviteStore as store } from "../services/teams/repository";

const runDbTests = process.env.CMUX_DB_TEST === "1";
const dbTest = runDbTests ? test : test.skip;
const TEAM = "11111111-1111-4111-8111-111111111111";

let sql: Sql | null = null;

beforeAll(() => {
  if (!runDbTests) return;
  const databaseURL = process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL;
  if (!databaseURL) throw new Error("DATABASE_URL is required when CMUX_DB_TEST=1");
  sql = postgres(databaseURL, { max: 2 });
});

beforeEach(async () => {
  if (!sql) return;
  await sql`truncate team_invite_link_redemptions, team_invite_links, team_invite_roles`;
});

afterAll(async () => {
  await closeCloudDbForTests();
  await sql?.end();
});

/** Compare errors as booleans: printing a driver error object can stall the reporter. */
async function rejects(operation: () => Promise<unknown>): Promise<boolean> {
  try {
    await operation();
    return false;
  } catch {
    return true;
  }
}

function hash(seed: string): string {
  return seed.repeat(64).slice(0, 64);
}

async function link(input: { maxUses?: number | null; expiresAt?: Date | null; seed?: string } = {}) {
  return store.createLink({
    stackTeamId: TEAM,
    tokenHash: hash(input.seed ?? "a"),
    createdByUserId: "admin",
    expiresAt: input.expiresAt ?? null,
    maxUses: input.maxUses ?? null,
  });
}

describe("team invite link claims", () => {
  dbTest("concurrent claims never exceed max uses", async () => {
    const created = await link({ maxUses: 3 });
    const results = await Promise.all(Array.from({ length: 12 }, (_, index) => store.claimLink(created.id, `user-${index}`)));
    expect(results.filter((result) => result === "claimed")).toHaveLength(3);
    expect(results.filter((result) => result === "unavailable")).toHaveLength(9);
    const [row] = await sql!`select use_count from team_invite_links where id = ${created.id}`;
    expect(row!.use_count).toBe(3);
    const [redemptions] = await sql!`select count(*)::int as count from team_invite_link_redemptions`;
    expect(redemptions!.count).toBe(3);
  });

  dbTest("a repeated claim is idempotent and release frees the slot", async () => {
    const created = await link({ maxUses: 1 });
    expect(await store.claimLink(created.id, "u1")).toBe("claimed");
    expect(await store.claimLink(created.id, "u1")).toBe("already_redeemed");
    expect(await store.claimLink(created.id, "u2")).toBe("unavailable");
    await store.releaseLinkClaim(created.id, "u1");
    await store.releaseLinkClaim(created.id, "u1");
    expect(await store.claimLink(created.id, "u2")).toBe("claimed");
    const [row] = await sql!`select use_count from team_invite_links where id = ${created.id}`;
    expect(row!.use_count).toBe(1);
  });

  dbTest("a stored role is bound to one invitation and a re-invite clears the binding", async () => {
    await store.upsertInviteRole({ stackTeamId: TEAM, email: "b@example.com", role: "admin", invitedByUserId: "admin" });
    await store.bindInviteRoleInvitation(TEAM, "b@example.com", "inv-1");
    await store.bindInviteRoleInvitation(TEAM, "missing@example.com", "inv-9");
    expect(await store.inviteRoles(TEAM, ["b@example.com", "missing@example.com"])).toEqual(
      new Map([["b@example.com", { role: "admin", stackInvitationId: "inv-1" }]]),
    );
    await store.upsertInviteRole({ stackTeamId: TEAM, email: "b@example.com", role: "admin", invitedByUserId: "admin" });
    expect((await store.inviteRoles(TEAM, ["b@example.com"])).get("b@example.com")).toEqual({ role: "admin", stackInvitationId: null });
  });

  dbTest("forgetting a departed member's redemptions keeps the spent use", async () => {
    const created = await link({ maxUses: 1 });
    const otherTeam = await store.createLink({
      stackTeamId: "22222222-2222-4222-8222-222222222222",
      tokenHash: hash("f"),
      createdByUserId: "admin",
      expiresAt: null,
      maxUses: null,
    });
    expect(await store.claimLink(created.id, "u1")).toBe("claimed");
    expect(await store.claimLink(otherTeam.id, "u1")).toBe("claimed");
    await store.forgetLinkRedemptions(TEAM, "u1");
    // The single use stays spent, so the departed member cannot claim again.
    expect(await store.claimLink(created.id, "u1")).toBe("unavailable");
    // Another team's redemption is untouched.
    expect(await store.claimLink(otherTeam.id, "u1")).toBe("already_redeemed");
    const [row] = await sql!`select use_count from team_invite_links where id = ${created.id}`;
    expect(row!.use_count).toBe(1);
  });

  dbTest("expired and revoked links are neither found nor claimable", async () => {
    const expired = await link({ seed: "b", expiresAt: new Date(Date.now() - 1000) });
    expect(await store.findActiveLinkByTokenHash(hash("b"))).toBeNull();
    expect(await store.claimLink(expired.id, "u1")).toBe("unavailable");

    const live = await link({ seed: "c" });
    expect((await store.findActiveLinkByTokenHash(hash("c")))?.id).toBe(live.id);
    expect(await store.revokeLink(TEAM, live.id)).toBe(true);
    expect(await store.revokeLink(TEAM, live.id)).toBe(true);
    expect(await store.revokeLink("22222222-2222-4222-8222-222222222222", live.id)).toBe(false);
    expect(await store.findActiveLinkByTokenHash(hash("c"))).toBeNull();
    expect(await store.claimLink(live.id, "u1")).toBe("unavailable");
    const [row] = await sql!`select revoked_at from team_invite_links where id = ${live.id}`;
    expect(row!.revoked_at).not.toBeNull();
    expect(await store.listActiveLinks(TEAM)).toEqual([]);
  });

  dbTest("invite roles upsert per lowercase email and a link can only grant member", async () => {
    await store.upsertInviteRole({ stackTeamId: TEAM, email: "a@example.com", role: "admin", invitedByUserId: "admin" });
    await store.upsertInviteRole({ stackTeamId: TEAM, email: "a@example.com", role: "member", invitedByUserId: "admin" });
    expect(await store.inviteRoles(TEAM, ["a@example.com"])).toEqual(new Map([["a@example.com", { role: "member", stackInvitationId: null }]]));
    expect(await rejects(() => store.upsertInviteRole({ stackTeamId: TEAM, email: "A@example.com", role: "admin", invitedByUserId: "x" }))).toBe(true);
    expect(await rejects(async () => {
      await sql!`insert into team_invite_links (stack_team_id, token_hash, role, created_by_user_id) values (${TEAM}, ${hash("d")}, 'admin', 'x')`;
    })).toBe(true);
  });
});
