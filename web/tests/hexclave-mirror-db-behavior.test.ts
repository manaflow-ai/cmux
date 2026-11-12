import { afterAll, beforeAll, beforeEach, expect, test } from "bun:test";
import { setTimeout as sleep } from "node:timers/promises";
import postgres, { type Sql } from "postgres";
import { cloudDb, closeCloudDbForTests } from "../db/client";
import { createDrizzleHexclaveMirrorStore, type HexclaveUserState } from "../services/auth/hexclave/mirrorStore";
import {
  OTHER_TEAM_ID,
  projectPermission,
  serverTeam,
  serverUser,
  TEAM_ID,
  teamPermission,
  USER_ID,
} from "./helpers/hexclave-fixtures";

const enabled = process.env.CMUX_DB_TEST === "1";
const dbTest = enabled ? test : test.skip;
let sql: Sql;

beforeAll(() => {
  if (!enabled) return;
  sql = postgres(process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL!, { max: 2 });
});
beforeEach(async () => {
  if (!enabled) return;
  await sql`truncate hexclave_pending_revocations, hexclave_team_permissions, hexclave_project_permissions, hexclave_team_memberships, hexclave_users, hexclave_teams, hexclave_tombstones, hexclave_webhook_events`;
});
afterAll(async () => {
  if (!enabled) return;
  await closeCloudDbForTests();
  await sql.end();
});

const store = () => createDrizzleHexclaveMirrorStore(cloudDb);

function present(overrides: Partial<Extract<HexclaveUserState, { kind: "present" }>> = {}): HexclaveUserState {
  return {
    kind: "present",
    user: serverUser(),
    teams: [serverTeam()],
    teamPermissions: [teamPermission()],
    projectPermissions: [projectPermission()],
    ...overrides,
  };
}

const deferred = <T>() => {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((r) => { resolve = r; });
  return { promise, resolve };
};

dbTest("mirrors a user with memberships and direct permissions, typed raw included", async () => {
  const result = await store().reconcileUser(USER_ID, async () => present({
    // A permission on a team the user is not in cannot be mirrored (FK to membership).
    teamPermissions: [teamPermission(), teamPermission({ team_id: OTHER_TEAM_ID })],
  }));
  expect(result.currentTeamIds).toEqual([TEAM_ID]);
  const [user] = await sql`select primary_email, is_anonymous, signed_up_at, raw from hexclave_users where id = ${USER_ID}`;
  expect(user!.primary_email).toBe("test@example.com");
  expect(user!.is_anonymous).toBe(false);
  expect(new Date(user!.signed_up_at as string).getTime()).toBe(serverUser().signed_up_at_millis);
  expect(user!.raw).toEqual(serverUser());
  expect(await sql`select team_id, user_id from hexclave_team_memberships`).toEqual([{ team_id: TEAM_ID, user_id: USER_ID }]);
  expect(await sql`select team_id, permission_id from hexclave_team_permissions`).toEqual([{ team_id: TEAM_ID, permission_id: "team_member" }]);
  expect(await sql`select permission_id from hexclave_project_permissions`).toEqual([{ permission_id: "test_permission" }]);
  const [team] = await sql`select display_name, client_read_only_metadata from hexclave_teams where id = ${TEAM_ID}`;
  expect(team).toEqual({ display_name: "Acme", client_read_only_metadata: { plan: "team" } });
});

dbTest("a gone user is tombstoned and its memberships and permissions cascade away", async () => {
  await store().reconcileUser(USER_ID, async () => present());
  const result = await store().reconcileUser(USER_ID, async () => ({ kind: "gone" }));
  expect(result.previousTeamIds).toEqual([TEAM_ID]);
  expect(await sql`select count(*)::int as n from hexclave_users`).toEqual([{ n: 0 }]);
  expect(await sql`select count(*)::int as n from hexclave_team_memberships`).toEqual([{ n: 0 }]);
  expect(await sql`select count(*)::int as n from hexclave_team_permissions`).toEqual([{ n: 0 }]);
  expect(await sql`select count(*)::int as n from hexclave_project_permissions`).toEqual([{ n: 0 }]);
  expect(await sql`select entity_type from hexclave_tombstones where entity_id = ${USER_ID}`).toEqual([{ entity_type: "user" }]);
  // The team itself is not the user's to delete.
  expect(await sql`select count(*)::int as n from hexclave_teams`).toEqual([{ n: 1 }]);
});

/** Poll pg_locks until some session waits on an advisory lock; bounded, condition-based. */
async function waitForAdvisoryLockWaiter(timeoutMs = 10_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const [row] = await sql`select count(*)::int as n from pg_locks where locktype = 'advisory' and not granted`;
    if (row!.n > 0) return;
    await sleep(10);
  }
  throw new Error("no session waited on an advisory lock");
}

dbTest("concurrent reconciles of one user apply in read order, so the later read wins", async () => {
  const firstHoldsLock = deferred<void>();
  const slowStale = deferred<HexclaveUserState>();
  const first = store().reconcileUser(USER_ID, () => {
    // `read` runs only after pg_advisory_xact_lock returned.
    firstHoldsLock.resolve();
    return slowStale.promise;
  });
  await firstHoldsLock.promise;
  let secondRead = false;
  const second = store().reconcileUser(USER_ID, async () => {
    secondRead = true;
    return present({ user: serverUser({ display_name: "fresh" }), teams: [], teamPermissions: [] });
  });
  await waitForAdvisoryLockWaiter();
  expect(secondRead).toBe(false);
  slowStale.resolve(present({ user: serverUser({ display_name: "stale" }) }));
  await Promise.all([first, second]);
  const [user] = await sql`select display_name from hexclave_users where id = ${USER_ID}`;
  expect(user!.display_name).toBe("fresh");
  expect(await sql`select count(*)::int as n from hexclave_team_memberships`).toEqual([{ n: 0 }]);
});

dbTest("a user read taken before a team deletion cannot write the team back", async () => {
  await store().reconcileUser(USER_ID, async () => present());
  const holdsLock = deferred<void>();
  const staleRead = deferred<HexclaveUserState>();
  const userReconcile = store().reconcileUser(USER_ID, () => {
    holdsLock.resolve();
    return staleRead.promise;
  });
  await holdsLock.promise;
  // The team deletion commits while the user reconcile still holds its stale read.
  await store().reconcileTeam(TEAM_ID, async () => null);
  staleRead.resolve(present());
  const result = await userReconcile;
  expect(result.currentTeamIds).toEqual([]);
  expect(await sql`select count(*)::int as n from hexclave_teams`).toEqual([{ n: 0 }]);
  expect(await sql`select count(*)::int as n from hexclave_team_memberships`).toEqual([{ n: 0 }]);
  expect(await sql`select count(*)::int as n from hexclave_users`).toEqual([{ n: 1 }]);
});

dbTest("tombstones are permanent: a later present read does not bring a user or team back", async () => {
  await store().reconcileUser(USER_ID, async () => present());
  await store().reconcileUser(USER_ID, async () => ({ kind: "gone" }));
  const user = await store().reconcileUser(USER_ID, async () => present());
  expect(user.state.kind).toBe("gone");
  await store().reconcileTeam(OTHER_TEAM_ID, async () => null);
  expect((await store().reconcileTeam(OTHER_TEAM_ID, async () => serverTeam({ id: OTHER_TEAM_ID }))).team).toBeNull();
  expect(await sql`select count(*)::int as n from hexclave_users`).toEqual([{ n: 0 }]);
  expect(await sql`select count(*)::int as n from hexclave_teams where id = ${OTHER_TEAM_ID}`).toEqual([{ n: 0 }]);
});

dbTest("a removed membership is persisted as a pending revocation until cleared, and a re-add drops it", async () => {
  const mirror = store();
  await mirror.reconcileUser(USER_ID, async () => present());
  const removed = await mirror.reconcileUser(USER_ID, async () => present({ teams: [], teamPermissions: [] }));
  expect(removed.pendingRevocationTeamIds).toEqual([TEAM_ID]);
  // The retry no longer sees the membership but still sees the pending row.
  const retry = await mirror.reconcileUser(USER_ID, async () => present({ teams: [], teamPermissions: [] }));
  expect(retry.pendingRevocationTeamIds).toEqual([TEAM_ID]);
  expect(await mirror.isRevocationPending({ teamId: TEAM_ID, userId: USER_ID })).toBe(true);
  await mirror.clearPendingRevocation({ teamId: TEAM_ID, userId: USER_ID });
  expect(await mirror.isRevocationPending({ teamId: TEAM_ID, userId: USER_ID })).toBe(false);

  await mirror.reconcileUser(USER_ID, async () => present({ teams: [], teamPermissions: [] }), { revokeCandidateTeamIds: [TEAM_ID] });
  expect(await mirror.isRevocationPending({ teamId: TEAM_ID, userId: USER_ID })).toBe(true);
  const readded = await mirror.reconcileUser(USER_ID, async () => present());
  expect(readded.pendingRevocationTeamIds).toEqual([]);
  expect(await sql`select count(*)::int as n from hexclave_pending_revocations`).toEqual([{ n: 0 }]);
});

dbTest("a user reconcile does not overwrite a team row with its older listing", async () => {
  await store().reconcileTeam(TEAM_ID, async () => serverTeam({ display_name: "Renamed" }));
  await store().reconcileUser(USER_ID, async () => present({ teams: [serverTeam({ display_name: "Acme" })] }));
  const [team] = await sql`select display_name from hexclave_teams where id = ${TEAM_ID}`;
  expect(team!.display_name).toBe("Renamed");
});

dbTest("team reconcile reports members and removes their rows when the team is gone", async () => {
  await store().reconcileUser(USER_ID, async () => present());
  const result = await store().reconcileTeam(TEAM_ID, async () => null);
  expect(result).toEqual({ team: null, memberIds: [USER_ID] });
  expect(await sql`select count(*)::int as n from hexclave_team_permissions`).toEqual([{ n: 0 }]);
  expect(await sql`select entity_type from hexclave_tombstones where entity_id = ${TEAM_ID}`).toEqual([{ entity_type: "team" }]);
});

dbTest("event records: processed stays processed, failures and invalid bodies stay retryable", async () => {
  const mirror = store();
  await mirror.recordEvent({ svixId: "msg_1", eventType: "user.updated", outcome: "failed" });
  expect(await mirror.isEventProcessed("msg_1")).toBe(false);
  await mirror.recordEvent({ svixId: "msg_1", eventType: "user.updated", outcome: "processed" });
  expect(await mirror.isEventProcessed("msg_1")).toBe(true);
  await mirror.recordEvent({ svixId: "msg_1", eventType: "user.updated", outcome: "failed" });
  expect(await sql`select outcome, attempts, processed_at is not null as processed from hexclave_webhook_events`)
    .toEqual([{ outcome: "processed", attempts: 3, processed: true }]);
  await mirror.recordEvent({ svixId: "msg_2", eventType: "team.created", outcome: "invalid" });
  expect(await mirror.isEventProcessed("msg_2")).toBe(false);
});

dbTest("snapshot writes skip entities the mirror wrote or tombstoned after the snapshot started", async () => {
  const mirror = store();
  const snapshotStartedAt = new Date(Date.now() - 60_000);
  await mirror.reconcileUser(USER_ID, async () => present({ user: serverUser({ display_name: "fresh" }), teams: [], teamPermissions: [] }));
  await mirror.reconcileTeam(OTHER_TEAM_ID, async () => null);
  const staleUser = present() as Extract<HexclaveUserState, { kind: "present" }>;
  expect(await mirror.applySnapshotUser(staleUser, snapshotStartedAt)).toBe(false);
  expect(await mirror.applySnapshotTeam(serverTeam({ id: OTHER_TEAM_ID }), snapshotStartedAt)).toBe(false);
  const [user] = await sql`select display_name from hexclave_users where id = ${USER_ID}`;
  expect(user!.display_name).toBe("fresh");
  expect(await sql`select count(*)::int as n from hexclave_teams where id = ${OTHER_TEAM_ID}`).toEqual([{ n: 0 }]);
  // A snapshot started after those writes applies (the tombstoned team still never does).
  const laterSnapshot = new Date(Date.now() + 60_000);
  expect(await mirror.applySnapshotTeam(serverTeam(), laterSnapshot)).toBe(true);
  expect(await mirror.applySnapshotTeam(serverTeam({ id: OTHER_TEAM_ID }), laterSnapshot)).toBe(false);
  expect(await mirror.applySnapshotUser(staleUser, laterSnapshot)).toBe(true);
  expect(await sql`select team_id from hexclave_team_memberships`).toEqual([{ team_id: TEAM_ID }]);
});
