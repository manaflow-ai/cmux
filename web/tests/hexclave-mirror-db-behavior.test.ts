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
  await sql`truncate hexclave_team_permissions, hexclave_project_permissions, hexclave_team_memberships, hexclave_users, hexclave_teams, hexclave_tombstones, hexclave_webhook_events`;
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

dbTest("concurrent reconciles of one user apply in read order, so the later read wins", async () => {
  const slowStale = deferred<HexclaveUserState>();
  const first = store().reconcileUser(USER_ID, () => slowStale.promise);
  // Give the first transaction time to take the user lock.
  await sleep(50);
  let secondReadAt = 0;
  const second = store().reconcileUser(USER_ID, async () => {
    secondReadAt = Date.now();
    return present({ user: serverUser({ display_name: "fresh" }), teams: [], teamPermissions: [] });
  });
  await sleep(50);
  expect(secondReadAt).toBe(0); // blocked behind the first reconcile's lock
  slowStale.resolve(present({ user: serverUser({ display_name: "stale" }) }));
  await Promise.all([first, second]);
  const [user] = await sql`select display_name from hexclave_users where id = ${USER_ID}`;
  expect(user!.display_name).toBe("fresh");
  expect(await sql`select count(*)::int as n from hexclave_team_memberships`).toEqual([{ n: 0 }]);
});

dbTest("a user read taken before a team deletion cannot write the team back", async () => {
  await store().reconcileUser(USER_ID, async () => present());
  const staleRead = deferred<HexclaveUserState>();
  const userReconcile = store().reconcileUser(USER_ID, () => staleRead.promise);
  await sleep(50);
  // The team deletion commits while the user reconcile still holds its stale read.
  await store().reconcileTeam(TEAM_ID, async () => null);
  staleRead.resolve(present());
  const result = await userReconcile;
  expect(result.currentTeamIds).toEqual([]);
  expect(await sql`select count(*)::int as n from hexclave_teams`).toEqual([{ n: 0 }]);
  expect(await sql`select count(*)::int as n from hexclave_team_memberships`).toEqual([{ n: 0 }]);
  expect(await sql`select count(*)::int as n from hexclave_users`).toEqual([{ n: 1 }]);
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
  const snapshotStartedAt = new Date();
  await sleep(5);
  await mirror.reconcileUser(USER_ID, async () => present({ user: serverUser({ display_name: "fresh" }), teams: [], teamPermissions: [] }));
  await mirror.reconcileTeam(OTHER_TEAM_ID, async () => null);
  const staleUser = present() as Extract<HexclaveUserState, { kind: "present" }>;
  expect(await mirror.applySnapshotUser(staleUser, snapshotStartedAt)).toBe(false);
  expect(await mirror.applySnapshotTeam(serverTeam({ id: OTHER_TEAM_ID }), snapshotStartedAt)).toBe(false);
  const [user] = await sql`select display_name from hexclave_users where id = ${USER_ID}`;
  expect(user!.display_name).toBe("fresh");
  expect(await sql`select count(*)::int as n from hexclave_teams where id = ${OTHER_TEAM_ID}`).toEqual([{ n: 0 }]);
  // A later snapshot is not older than those writes, so it applies.
  expect(await mirror.applySnapshotTeam(serverTeam(), new Date())).toBe(true);
  expect(await mirror.applySnapshotUser(staleUser, new Date())).toBe(true);
  expect(await sql`select team_id from hexclave_team_memberships`).toEqual([{ team_id: TEAM_ID }]);
});
