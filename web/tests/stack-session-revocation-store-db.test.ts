import { afterAll, beforeEach, describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import postgres from "postgres";

import { closeCloudDbForTests, cloudDb } from "../db/client";
import { vmRepositoryLiveShape as liveVmRepository } from "../services/vms/repository";
import {
  databaseStackSessionRevocationStore,
  deleteStackSessionRevocationsForUser,
} from "../services/vms/stackSessionRevocationStore";
import {
  retryPendingStackSessionRevocations,
  STACK_SESSION_REVOCATION_POLICY,
} from "../services/vms/stackSessionRevocations";

const runDbTests = process.env.CMUX_DB_TEST === "1";
const dbTest = runDbTests ? test : test.skip;
const sql = runDbTests ? postgres((process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL)!, { max: 1 }) : null;

const USER = "revocation-user-1";

beforeEach(async () => {
  if (!sql) return;
  await sql`drop trigger if exists stack_session_revocations_crash on stack_session_revocations`;
  await sql`drop function if exists stack_session_revocations_crash()`;
  await sql`truncate stack_session_revocations, cloud_vm_access_grant_sessions, cloud_vm_access_grants restart identity cascade`;
});

afterAll(async () => {
  if (sql) {
    await sql`drop trigger if exists stack_session_revocations_crash on stack_session_revocations`;
    await sql`drop function if exists stack_session_revocations_crash()`;
  }
  await closeCloudDbForTests();
  await sql?.end();
});

async function grantWithSessions(sessionIds: readonly string[]): Promise<string> {
  const [grant] = await sql!<{ id: string }[]>`
    insert into cloud_vm_access_grants (user_id, device_id) values (${USER}, ${`device-${sessionIds.join("-")}`}) returning id
  `;
  for (const sessionId of sessionIds) {
    await sql!`
      insert into cloud_vm_access_grant_sessions (access_grant_id, user_id, stack_session_id, session_issued_at)
      values (${grant!.id}, ${USER}, ${sessionId}, now())
    `;
  }
  return grant!.id;
}

async function queue(sessionIds: readonly string[], nextAttemptAt = new Date(0)): Promise<void> {
  for (const sessionId of sessionIds) {
    await sql!`
      insert into stack_session_revocations (stack_session_id, user_id, next_attempt_at)
      values (${sessionId}, ${USER}, ${nextAttemptAt})
    `;
  }
}

describe("stack session revocation queue", () => {
  dbTest("revoking a grant queues its sessions in the same transaction", async () => {
    const grantId = await grantWithSessions(["s1", "s2"]);
    const result = await Effect.runPromise(liveVmRepository.revokeAccessGrant!({
      id: grantId,
      revokeStackSessions: { userId: USER, firstRetryAt: new Date(Date.now() + 120_000) },
    }));
    expect(result).toEqual({ revoked: true, stackSessionIds: ["s1", "s2"] });
    const queued = await sql!<{ stack_session_id: string; user_id: string; access_grant_id: string }[]>`
      select stack_session_id, user_id, access_grant_id from stack_session_revocations order by stack_session_id
    `;
    expect(queued).toEqual([
      { stack_session_id: "s1", user_id: USER, access_grant_id: grantId },
      { stack_session_id: "s2", user_id: USER, access_grant_id: grantId },
    ]);
  });

  dbTest("a crash between the grant revocation and the queue insert rolls both back", async () => {
    const grantId = await grantWithSessions(["s1"]);
    await sql!.unsafe(`
      create function stack_session_revocations_crash() returns trigger language plpgsql as $$
      begin raise exception 'simulated crash'; end $$;
      create trigger stack_session_revocations_crash before insert on stack_session_revocations
        for each row execute function stack_session_revocations_crash();
    `);
    await expect(Effect.runPromise(liveVmRepository.revokeAccessGrant!({
      id: grantId,
      revokeStackSessions: { userId: USER, firstRetryAt: new Date() },
    }))).rejects.toBeDefined();
    const [grant] = await sql!<{ revoked_at: Date | null }[]>`select revoked_at from cloud_vm_access_grants where id = ${grantId}`;
    // Not revoked, so the caller sees the failure and the revoke can be retried
    // whole; never "grant revoked, sessions forgotten".
    expect(grant!.revoked_at).toBeNull();
  });

  dbTest("the Mac's own sign-out path revokes the grant without queueing sessions", async () => {
    const grantId = await grantWithSessions(["s1"]);
    await Effect.runPromise(liveVmRepository.revokeAccessGrant!({ id: grantId, revokeStackSessions: null }));
    const [{ count }] = await sql!<{ count: number }[]>`select count(*)::int as count from stack_session_revocations`;
    expect(count).toBe(0);
  });

  dbTest("two concurrent cron runs claim disjoint rows and revoke each session once", async () => {
    const ids = Array.from({ length: 8 }, (_, index) => `c${index}`);
    await queue(ids);
    const store = databaseStackSessionRevocationStore();
    const revoked: string[] = [];
    let release!: () => void;
    const gate = new Promise<void>((resolve) => { release = resolve; });
    const revoke = async (id: string) => {
      revoked.push(id);
      await gate;
    };
    const runA = retryPendingStackSessionRevocations({ store, revoke, limit: 5 });
    const runB = retryPendingStackSessionRevocations({ store, revoke, limit: 5 });
    // Both runs have claimed before any revocation finishes.
    await new Promise<void>((resolve) => {
      const check = () => (revoked.length === ids.length ? resolve() : setImmediate(check));
      check();
    });
    release();
    const [a, b] = await Promise.all([runA, runB]);
    expect(a.attempted + b.attempted).toBe(ids.length);
    expect([...revoked].sort()).toEqual([...ids].sort());
    const [{ count }] = await sql!<{ count: number }[]>`select count(*)::int as count from stack_session_revocations`;
    expect(count).toBe(0);
  });

  dbTest("a claimed row is not claimed again until its lease expires", async () => {
    await queue(["l1"]);
    const store = databaseStackSessionRevocationStore();
    const now = new Date();
    expect(await store.claimDue(now, 10, new Date(now.getTime() + 60_000))).toHaveLength(1);
    expect(await store.claimDue(new Date(now.getTime() + 30_000), 10, new Date(now.getTime() + 90_000))).toHaveLength(0);
    expect(await store.claimDue(new Date(now.getTime() + 61_000), 10, new Date(now.getTime() + 120_000))).toHaveLength(1);
  });

  dbTest("failures back off, then give up at the cap; a given-up row is never claimed again", async () => {
    await queue(["f1"]);
    const store = databaseStackSessionRevocationStore();
    const now = new Date();
    const first = await store.recordFailure("f1", { now, error: "Error: HTTP 429", policy: STACK_SESSION_REVOCATION_POLICY });
    expect(first).toEqual({ attempts: 1, gaveUp: false });
    const [row] = await sql!<{ next_attempt_at: Date; claimed_until: Date | null }[]>`
      select next_attempt_at, claimed_until from stack_session_revocations where stack_session_id = 'f1'
    `;
    expect(row!.next_attempt_at.getTime() - now.getTime()).toBe(STACK_SESSION_REVOCATION_POLICY.baseDelayMs);
    await sql!`update stack_session_revocations set attempts = ${STACK_SESSION_REVOCATION_POLICY.maxAttempts - 1}`;
    expect(await store.recordFailure("f1", { now, error: "Error: HTTP 429", policy: STACK_SESSION_REVOCATION_POLICY }))
      .toEqual({ attempts: STACK_SESSION_REVOCATION_POLICY.maxAttempts, gaveUp: true });
    // Terminal: no further failure is recorded (so no second report) and no claim.
    expect(await store.recordFailure("f1", { now, error: "x", policy: STACK_SESSION_REVOCATION_POLICY })).toBeNull();
    expect(await store.claimDue(new Date(now.getTime() + 365 * 24 * 3_600_000), 10, new Date())).toEqual([]);
  });

  dbTest("a row older than a day gives up on its next failure", async () => {
    await queue(["old"]);
    await sql!`update stack_session_revocations set created_at = now() - interval '25 hours'`;
    const result = await databaseStackSessionRevocationStore().recordFailure("old", {
      now: new Date(),
      error: "Error: HTTP 503",
      policy: STACK_SESSION_REVOCATION_POLICY,
    });
    expect(result).toEqual({ attempts: 1, gaveUp: true });
  });

  dbTest("account deletion purges the user's rows only", async () => {
    await queue(["u1"]);
    await sql!`insert into stack_session_revocations (stack_session_id, user_id) values ('other', 'someone-else')`;
    await deleteStackSessionRevocationsForUser(cloudDb(), USER);
    const left = await sql!<{ stack_session_id: string }[]>`select stack_session_id from stack_session_revocations`;
    expect(left).toEqual([{ stack_session_id: "other" }]);
  });
});
