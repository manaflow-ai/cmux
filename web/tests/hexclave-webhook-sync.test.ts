import { describe, expect, test } from "bun:test";
import { createHmac } from "node:crypto";
import { applyHexclaveWebhookEvent, type HexclaveSyncDependencies } from "../services/auth/hexclave/sync";
import { hexclaveWebhookEventTypes } from "../services/auth/hexclave/webhookEvents";
import { handleStackWebhook, type StackWebhookDependencies } from "../services/auth/stackWebhook";
import {
  OTHER_TEAM_ID,
  OTHER_USER_ID,
  projectPermission,
  serverTeam,
  serverUser,
  TEAM_ID,
  teamPermission,
  USER_ID,
  validWebhookData,
} from "./helpers/hexclave-fixtures";
import { FakeHexclave, MemoryMirror } from "./helpers/hexclave-memory";

const KEY = Buffer.from("hexclave-webhook-test-key-0123456789");
const SECRET = `whsec_${KEY.toString("base64")}`;
const NOW = 1_800_000_000;

function harness(options: { sync?: Partial<HexclaveSyncDependencies>; deps?: Partial<StackWebhookDependencies> } = {}) {
  const hexclave = new FakeHexclave();
  const mirror = new MemoryMirror();
  const calls: string[] = [];
  const logs: { level: string; message: string; fields: Record<string, unknown> }[] = [];
  const sync: HexclaveSyncDependencies = {
    source: hexclave,
    store: mirror,
    revokeTeamMemberAccess: async ({ teamId, userId }) => { calls.push(`revoke-member:${teamId}:${userId}`); },
    revokeTeamAccess: async ({ teamId }) => { calls.push(`revoke-team:${teamId}`); },
    invalidateUser: async (userId) => { calls.push(`invalidate:${userId}`); },
    ...options.sync,
  };
  const dependencies: StackWebhookDependencies = {
    webhookSecret: () => SECRET,
    nowSeconds: () => NOW,
    sync: () => sync,
    log: (level, message, fields) => { logs.push({ level, message, fields }); },
    ...options.deps,
  };
  let counter = 0;
  const post = (type: string, data: unknown, svixId = `msg_${++counter}`) => {
    const body = JSON.stringify({ type, data });
    const signature = createHmac("sha256", KEY).update(`${svixId}.${NOW}.${body}`).digest("base64");
    return handleStackWebhook(new Request("https://cmux.test/api/webhooks/stack", {
      method: "POST",
      headers: { "content-type": "application/json", "svix-id": svixId, "svix-timestamp": String(NOW), "svix-signature": `v1,${signature}` },
      body,
    }), dependencies);
  };
  return { hexclave, mirror, calls, logs, post, sync };
}

/** Hexclave state: USER_ID in TEAM_ID with one team and one project permission. */
function seed(hexclave: FakeHexclave) {
  hexclave.users.set(USER_ID, serverUser());
  hexclave.teams.set(TEAM_ID, serverTeam());
  hexclave.addMember(TEAM_ID, USER_ID);
  hexclave.teamPermissions.push(teamPermission());
  hexclave.projectPermissions.push(projectPermission());
}

describe("Hexclave webhook boundary", () => {
  test("a missing webhook secret answers 503 and reads nothing", async () => {
    const { hexclave, calls, post } = harness({ deps: { webhookSecret: () => undefined } });
    expect((await post("user.created", serverUser())).status).toBe(503);
    expect(hexclave.calls).toEqual([]);
    expect(calls).toEqual([]);
  });

  test("a request signed with the wrong secret answers 401 and reads nothing", async () => {
    const { hexclave, post } = harness({ deps: { webhookSecret: () => `whsec_${Buffer.from("other").toString("base64")}` } });
    expect((await post("user.created", serverUser())).status).toBe(401);
    expect(hexclave.calls).toEqual([]);
  });

  test("missing server credentials answer 503 so Svix retries once configured", async () => {
    const { post } = harness({ deps: { sync: () => null } });
    expect((await post("user.created", serverUser())).status).toBe(503);
  });

  test("a schema failure answers 400, is logged and recorded, and is never processed", async () => {
    const { hexclave, mirror, calls, logs, post } = harness();
    const response = await post("team_membership.deleted", { team_id: TEAM_ID }, "msg_bad");
    expect(response.status).toBe(400);
    expect(hexclave.calls).toEqual([]);
    expect(calls).toEqual([]);
    expect(logs.find((entry) => entry.message === "stack_webhook_invalid_payload")?.fields.eventType).toBe("team_membership.deleted");
    expect(mirror.events.get("msg_bad")).toMatchObject({ outcome: "invalid", processed: false });
    // A redelivery is validated again, not short-circuited as processed.
    expect((await post("team_membership.deleted", { team_id: TEAM_ID }, "msg_bad")).status).toBe(400);
  });

  test("an unknown type answers 200 ignored and is logged", async () => {
    const { hexclave, logs, post } = harness();
    const response = await post("session.revoked", { id: USER_ID });
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ received: true, ignored: "session.revoked" });
    expect(hexclave.calls).toEqual([]);
    expect(logs.some((entry) => entry.message === "stack_webhook_unknown_event_type")).toBe(true);
  });

  test("a processed svix-id is acknowledged again without any work", async () => {
    const { hexclave, calls, post } = harness();
    seed(hexclave);
    expect((await post("user.updated", serverUser(), "msg_dup")).status).toBe(200);
    const reads = hexclave.calls.length;
    const sideEffects = calls.length;
    const again = await post("user.updated", serverUser(), "msg_dup");
    expect(again.status).toBe(200);
    expect(await again.json()).toEqual({ received: true, duplicate: true });
    expect(hexclave.calls.length).toBe(reads);
    expect(calls.length).toBe(sideEffects);
  });

  test("a failed Hexclave read answers 500, records the failure, and the retry succeeds", async () => {
    const { hexclave, mirror, post } = harness();
    seed(hexclave);
    hexclave.failNext = new Error("hexclave 502");
    expect((await post("user.created", serverUser(), "msg_retry")).status).toBe(500);
    expect(mirror.events.get("msg_retry")).toMatchObject({ outcome: "failed", processed: false });
    expect(mirror.users.has(USER_ID)).toBe(false);
    expect((await post("user.created", serverUser(), "msg_retry")).status).toBe(200);
    expect(mirror.users.get(USER_ID)?.id).toBe(USER_ID);
    expect(mirror.events.get("msg_retry")).toMatchObject({ outcome: "processed", processed: true, attempts: 2 });
  });

  test("a failed revocation answers 500 and the retry revokes again", async () => {
    let fail = true;
    const revoked: string[] = [];
    const { hexclave, post } = harness({
      sync: {
        revokeTeamMemberAccess: async ({ teamId, userId }) => {
          if (fail) { fail = false; throw new Error("provider down"); }
          revoked.push(`${teamId}:${userId}`);
        },
      },
    });
    seed(hexclave);
    hexclave.removeMember(TEAM_ID, USER_ID);
    expect((await post("team_membership.deleted", { team_id: TEAM_ID, user_id: USER_ID }, "msg_rev")).status).toBe(500);
    expect((await post("team_membership.deleted", { team_id: TEAM_ID, user_id: USER_ID }, "msg_rev")).status).toBe(200);
    expect(revoked).toEqual([`${TEAM_ID}:${USER_ID}`]);
  });

  test("a revoke that only the mirror knew about survives a failed attempt and runs on the retry", async () => {
    let fail = true;
    const revoked: string[] = [];
    const { hexclave, mirror, post } = harness({
      sync: {
        revokeTeamMemberAccess: async ({ teamId, userId }) => {
          if (fail) { fail = false; throw new Error("provider down"); }
          revoked.push(`${teamId}:${userId}`);
        },
      },
    });
    seed(hexclave);
    expect((await post("user.created", serverUser())).status).toBe(200);
    // The removal's own webhook is lost; a user.updated (no team in its payload) finds it.
    hexclave.removeMember(TEAM_ID, USER_ID);
    expect((await post("user.updated", serverUser(), "msg_upd")).status).toBe(500);
    expect(mirror.teamIdsFor(USER_ID)).toEqual([]);
    expect([...mirror.pendingRevocations]).toEqual([`${TEAM_ID}:${USER_ID}`]);
    expect((await post("user.updated", serverUser(), "msg_upd")).status).toBe(200);
    expect(revoked).toEqual([`${TEAM_ID}:${USER_ID}`]);
    expect(mirror.pendingRevocations.size).toBe(0);
  });

  test("a pending revoke is dropped, not run, when the member was added back", async () => {
    let fail = true;
    const { hexclave, mirror, calls, post } = harness({
      sync: {
        revokeTeamMemberAccess: async ({ teamId, userId }) => {
          if (fail) { fail = false; throw new Error("provider down"); }
          calls.push(`revoke-member:${teamId}:${userId}`);
        },
      },
    });
    seed(hexclave);
    await post("user.created", serverUser());
    hexclave.removeMember(TEAM_ID, USER_ID);
    expect((await post("user.updated", serverUser())).status).toBe(500);
    hexclave.addMember(TEAM_ID, USER_ID);
    calls.length = 0;
    expect((await post("team_membership.created", { team_id: TEAM_ID, user_id: USER_ID })).status).toBe(200);
    expect(calls).toEqual([`invalidate:${USER_ID}`]);
    expect(mirror.pendingRevocations.size).toBe(0);
  });

  test("a failed snapshot invalidation answers 500", async () => {
    const { hexclave, post } = harness({ sync: { invalidateUser: async () => { throw new Error("db down"); } } });
    seed(hexclave);
    expect((await post("team_permission.created", teamPermission())).status).toBe(500);
  });
});

describe("Hexclave mirror reconcile", () => {
  test("every event type reconciles from Hexclave, not from its payload", async () => {
    for (const type of hexclaveWebhookEventTypes) {
      const { hexclave, mirror, post } = harness();
      seed(hexclave);
      expect((await post(type, validWebhookData[type])).status).toBe(200);
      expect(hexclave.calls.length).toBeGreaterThan(0);
      if (type.startsWith("team.")) expect(mirror.teams.get(TEAM_ID)).toEqual(serverTeam());
      else expect(mirror.users.get(USER_ID)).toEqual(serverUser());
    }
  });

  test("a user reconcile mirrors the user, memberships, and direct permissions", async () => {
    const { hexclave, mirror, calls, post } = harness();
    seed(hexclave);
    hexclave.teams.set(OTHER_TEAM_ID, serverTeam({ id: OTHER_TEAM_ID, display_name: "Other" }));
    hexclave.addMember(OTHER_TEAM_ID, USER_ID);
    expect((await post("team_membership.created", { team_id: OTHER_TEAM_ID, user_id: USER_ID })).status).toBe(200);
    expect(mirror.teamIdsFor(USER_ID)).toEqual([OTHER_TEAM_ID, TEAM_ID].sort());
    expect([...mirror.teamPermissions]).toEqual([`${TEAM_ID}:${USER_ID}:team_member`]);
    expect([...mirror.projectPermissions]).toEqual([`${USER_ID}:test_permission`]);
    expect(calls).toEqual([`invalidate:${USER_ID}`]);
  });

  test("permission removal is mirrored and invalidates the user's snapshot", async () => {
    const { hexclave, mirror, calls, post } = harness();
    seed(hexclave);
    await post("user.created", serverUser());
    hexclave.projectPermissions = [];
    hexclave.teamPermissions = [];
    calls.length = 0;
    expect((await post("project_permission.deleted", projectPermission())).status).toBe(200);
    expect(mirror.projectPermissions.size).toBe(0);
    expect(mirror.teamPermissions.size).toBe(0);
    expect(calls).toEqual([`invalidate:${USER_ID}`]);
  });

  test("user.deleted then a late user.updated does not resurrect the user", async () => {
    const { hexclave, mirror, calls, post } = harness();
    seed(hexclave);
    await post("user.created", serverUser());
    hexclave.deleteUser(USER_ID);
    calls.length = 0;
    expect((await post("user.deleted", { id: USER_ID, teams: [{ id: TEAM_ID }] })).status).toBe(200);
    expect(mirror.users.has(USER_ID)).toBe(false);
    expect(mirror.teamIdsFor(USER_ID)).toEqual([]);
    expect(mirror.projectPermissions.size).toBe(0);
    expect(calls).toEqual([`revoke-member:${TEAM_ID}:${USER_ID}`, `invalidate:${USER_ID}`]);

    // Svix delivers an older update after the deletion; its payload still shows the user.
    expect((await post("user.updated", serverUser({ display_name: "stale" }))).status).toBe(200);
    expect(mirror.users.has(USER_ID)).toBe(false);
    expect(mirror.tombstones.has(`user:${USER_ID}`)).toBe(true);

    // Even a lagging Hexclave read that still returns the user cannot bring it back.
    hexclave.users.set(USER_ID, serverUser({ display_name: "stale read" }));
    expect((await post("user.updated", serverUser())).status).toBe(200);
    expect(mirror.users.has(USER_ID)).toBe(false);
  });

  test("membership deleted then a late membership.created does not re-add it", async () => {
    const { hexclave, mirror, post } = harness();
    seed(hexclave);
    await post("user.created", serverUser());
    hexclave.removeMember(TEAM_ID, USER_ID);
    await post("team_membership.deleted", { team_id: TEAM_ID, user_id: USER_ID });
    await post("team_membership.created", { team_id: TEAM_ID, user_id: USER_ID });
    expect(mirror.teamIdsFor(USER_ID)).toEqual([]);
    expect(mirror.teamPermissions.size).toBe(0);
  });

  test("team_membership.deleted revokes when Hexclave no longer lists the membership", async () => {
    const { hexclave, calls, post } = harness();
    seed(hexclave);
    hexclave.removeMember(TEAM_ID, USER_ID);
    expect((await post("team_membership.deleted", { team_id: TEAM_ID, user_id: USER_ID })).status).toBe(200);
    expect(calls).toEqual([`revoke-member:${TEAM_ID}:${USER_ID}`, `invalidate:${USER_ID}`]);
  });

  test("a late team_membership.deleted does not revoke a member who was added back", async () => {
    const { hexclave, mirror, calls, post } = harness();
    seed(hexclave);
    expect((await post("team_membership.deleted", { team_id: TEAM_ID, user_id: USER_ID })).status).toBe(200);
    expect(calls).toEqual([`invalidate:${USER_ID}`]);
    expect(mirror.teamIdsFor(USER_ID)).toEqual([TEAM_ID]);
  });

  test("a membership removed while its event was lost is revoked by the next reconcile of that user", async () => {
    const { hexclave, calls, post } = harness();
    seed(hexclave);
    await post("user.created", serverUser());
    hexclave.removeMember(TEAM_ID, USER_ID);
    calls.length = 0;
    await post("user.updated", serverUser());
    expect(calls).toEqual([`revoke-member:${TEAM_ID}:${USER_ID}`, `invalidate:${USER_ID}`]);
  });

  test("team.deleted revokes the team, drops its rows, invalidates members, and a late team.updated does not resurrect it", async () => {
    const { hexclave, mirror, calls, post } = harness();
    seed(hexclave);
    hexclave.users.set(OTHER_USER_ID, serverUser({ id: OTHER_USER_ID, primary_email: "other@example.com" }));
    hexclave.addMember(TEAM_ID, OTHER_USER_ID);
    await post("user.created", serverUser());
    await post("user.created", serverUser({ id: OTHER_USER_ID }));
    hexclave.deleteTeam(TEAM_ID);
    calls.length = 0;
    expect((await post("team.deleted", { id: TEAM_ID })).status).toBe(200);
    expect(calls.sort()).toEqual([`invalidate:${OTHER_USER_ID}`, `invalidate:${USER_ID}`, `revoke-team:${TEAM_ID}`].sort());
    expect(mirror.teams.has(TEAM_ID)).toBe(false);
    expect(mirror.teamIdsFor(USER_ID)).toEqual([]);

    expect((await post("team.updated", serverTeam({ display_name: "stale" }))).status).toBe(200);
    expect(mirror.teams.has(TEAM_ID)).toBe(false);

    // A lagging read that still returns the team cannot bring it back either.
    hexclave.teams.set(TEAM_ID, serverTeam({ display_name: "stale read" }));
    expect((await post("team.updated", serverTeam())).status).toBe(200);
    expect(mirror.teams.has(TEAM_ID)).toBe(false);
  });

  test("a user reconcile that listed a team before its deletion does not write it back", async () => {
    const { hexclave, mirror, sync } = harness();
    seed(hexclave);
    hexclave.deleteTeam(TEAM_ID);
    await applyHexclaveWebhookEvent({ type: "team.deleted", data: { id: TEAM_ID } }, sync);
    // Simulate a user read taken just before the deletion committed.
    hexclave.teams.set(TEAM_ID, serverTeam());
    hexclave.addMember(TEAM_ID, USER_ID);
    await applyHexclaveWebhookEvent({ type: "user.updated", data: serverUser() }, sync);
    expect(mirror.teams.has(TEAM_ID)).toBe(false);
    expect(mirror.teamIdsFor(USER_ID)).toEqual([]);
  });

  test("team.updated refreshes the team row and invalidates members' snapshots", async () => {
    const { hexclave, mirror, calls, post } = harness();
    seed(hexclave);
    await post("user.created", serverUser());
    hexclave.teams.set(TEAM_ID, serverTeam({ display_name: "Renamed" }));
    calls.length = 0;
    await post("team.updated", serverTeam({ display_name: "payload is ignored" }));
    expect(mirror.teams.get(TEAM_ID)?.display_name).toBe("Renamed");
    expect(calls).toEqual([`invalidate:${USER_ID}`]);
  });
});
