/**
 * Mesh M4 (cx-0op.6, cx-0op.7).
 *
 * 1. Membership cache: a device-signed call by a user-owned device asks Stack
 *    once per 60 s (positive answers only); "not a member" is never cached.
 * 2. Device actor: device-signed actions are audited as the device, with the
 *    owner as a separate field.
 * 3. G1: the Stack team-membership webhook (Svix-signed) revokes the removed
 *    user's devices in that team at once: the cache entry first, then each
 *    tunnel by its recorded id, then the ACL. Bad, stale or unsigned
 *    deliveries change nothing; a retry is a no-op; without the secret the
 *    route answers 503.
 * 4. G1 retries and re-adds: a removal revokes every device that existed at
 *    the removal event (first receipt), also when the user was added back
 *    before the retry; a device enrolled after the event survives. Both
 *    orders: re-add before and after the retry. An event that finds nothing
 *    to revoke (no devices, a tenant outside the allowlist, Stack unable to
 *    answer for the user) is a recorded 200, never a 503.
 * 5. `user.deleted` revokes the user's devices in every tenant, without asking
 *    Stack about the deleted user, idempotently.
 * 6. One writer per mesh: a reconcile planned from an old ACL version cannot
 *    re-open a rule a concurrent apply removed.
 */
import { afterEach, describe, expect, it, vi } from "vitest";
import { Effect, Redacted } from "effect";
import { signWebhookContent } from "../../src/auth/webhook-signature.ts";
import { StoreError } from "../../src/db/sql.ts";
import { ALL_SCOPES, bearer } from "../support/endpoints.ts";
import { makeHarness, type HarnessOptions } from "../support/harness.ts";
import { deviceRequestBody, enrollBody, makeInstallKey, rotateBody, type InstallKey } from "../support/mesh-signing.ts";

type Harness = Awaited<ReturnType<typeof makeHarness>>;

const A = "team_alpha";
const B = "team_bravo";
const SECRET = `whsec_${btoa("m4-test-webhook-secret-32-bytes!")}`;
const KEY_1 = "dGVzdC1kZXZpY2UtcHVibGljLWtleS0wMDAwMDAwMDE=";
const KEY_2 = "dGVzdC1kZXZpY2UtcHVibGljLWtleS0wMDAwMDAwMDI=";
const KEY_3 = "dGVzdC1kZXZpY2UtcHVibGljLWtleS0wMDAwMDAwMDM=";
const KEY_4 = "dGVzdC1kZXZpY2UtcHVibGljLWtleS0wMDAwMDAwMDQ=";

let h: Harness;
const setup = async (options: HarnessOptions = { stackWebhookSecret: SECRET }) => {
  h = await makeHarness(options);
};
afterEach(async () => {
  await h.dispose();
});

const json = async (response: Response): Promise<Record<string, unknown>> => {
  const body: unknown = await response.json();
  return typeof body === "object" && body !== null ? Object.fromEntries(Object.entries(body)) : {};
};
const field = (value: unknown, key: string): unknown => (typeof value === "object" && value !== null ? Object.fromEntries(Object.entries(value))[key] : undefined);
const str = (value: unknown): string => (typeof value === "string" ? value : "");
const call = (path: string, headers: Record<string, string>, method = "GET", body?: unknown) => h.request(path, headers, { method, body });
const anonymous = (path: string, body?: unknown) => h.request(path, {}, { method: "POST", body });
const session = async (tenant: string, user: string) => ({ ...bearer(await h.sessionToken(user)), "x-cmux-team-id": tenant });

const tunnelDeletes = () => h.upstream.callsTo("DELETE", /^\/v5\/tunnels\/[^/]+$/u).map((entry) => entry.path.replace("/v5/tunnels/", ""));
const membershipDeleted = (tenant: string, user: string) => ({ type: "team_membership.deleted", data: { team_id: tenant, user_id: user } });

/** A mesh in `tenant` with one VM every device may reach on tcp 22, created by an admin key. */
const meshWithVm = async (tenant: string) => {
  const admin = bearer(await h.addKey(tenant, ALL_SCOPES));
  const created = await call("/v1/meshes", admin, "POST", { displayName: "m4" });
  expect(created.status).toBe(201);
  const meshId = str((await json(created))["id"]);
  const vm = h.addVm(tenant);
  expect((await call(`/v1/meshes/${meshId}/vms/${vm.vmId}`, admin, "PUT")).status).toBe(200);
  const acl = await call(`/v1/meshes/${meshId}/acl`, admin, "PUT", { expectedVersion: 0, rules: [{ src: ["device:*"], dst: ["vm:*"], allow: ["tcp:22"] }] });
  expect(acl.status).toBe(200);
  return { admin, meshId, vmId: vm.vmId };
};

/** Enrolls a device as the session of `user`; returns its id and tunnel's provider id. */
const sessionEnroll = async (tenant: string, user: string, meshId: string, install: InstallKey, wgPublicKey: string) => {
  const response = await call(`/v1/meshes/${meshId}/devices`, await session(tenant, user), "POST", await enrollBody(install, meshId, { name: "laptop", wgPublicKey }));
  expect(response.status).toBe(201);
  const deviceId = str(field(field(await json(response), "device"), "id"));
  return { deviceId, upstreamTunnel: tunnelOf(deviceId) };
};

/** Enrolls a headless device with a one-time code made by the session of `user`. */
const codeEnroll = async (tenant: string, user: string, meshId: string, install: InstallKey, wgPublicKey: string) => {
  const made = await call(`/v1/meshes/${meshId}/enrollment-codes`, await session(tenant, user), "POST", {});
  expect(made.status).toBe(201);
  const code = str((await json(made))["code"]);
  const response = await anonymous(`/v1/meshes/${meshId}/device-enrollments`, await enrollBody(install, meshId, { name: "headless", wgPublicKey, code }));
  expect(response.status).toBe(201);
  const deviceId = str(field(field(await json(response), "device"), "id"));
  return { deviceId, upstreamTunnel: tunnelOf(deviceId) };
};

/** The provider tunnel id recorded for a device (its ownership row's upstream id). */
const tunnelOf = (deviceId: string) => {
  const row = h.resources.find((resource) => resource.kind === "device" && resource.cmuxId === deviceId);
  if (row === undefined) throw new Error(`no ownership row for ${deviceId}`);
  return String(row.upstreamId);
};

const signedPeers = async (install: InstallKey, deviceId: string) => anonymous(`/v1/devices/${deviceId}/signed/peers`, await deviceRequestBody(install, deviceId, "peers"));

describe("membership cache (cx-0op.7)", () => {
  it("a user-owned device polling its peer map asks Stack once per 60 s, not once per call", async () => {
    await setup();
    h.addMember(A, "user_ada");
    const mesh = await meshWithVm(A);
    const install = await makeInstallKey();
    const { deviceId } = await codeEnroll(A, "user_ada", mesh.meshId, install, KEY_1);
    const before = h.stackMembershipCalls.length;
    for (let i = 0; i < 5; i++) expect((await signedPeers(install, deviceId)).status).toBe(200);
    expect(h.stackMembershipCalls.length - before).toBeLessThanOrEqual(1);
  });

  it("never caches 'not a member': a user added after a refusal works on the next call", async () => {
    await setup();
    const headers = await session(A, "user_late");
    expect((await call("/v1/meshes", headers)).status).toBe(403);
    expect((await call("/v1/meshes", headers)).status).toBe(403);
    expect(h.stackMembershipCalls.filter((user) => user === "user_late")).toHaveLength(2);
    h.addMember(A, "user_late");
    expect((await call("/v1/meshes", headers)).status).toBe(200);
  });
});

describe("device actor in the audit log (cx-0op.7)", () => {
  it("a device-signed rotation is audited as the device, with its owner in a separate field", async () => {
    await setup();
    h.addMember(A, "user_ada");
    const mesh = await meshWithVm(A);
    const install = await makeInstallKey();
    const { deviceId } = await codeEnroll(A, "user_ada", mesh.meshId, install, KEY_1);
    const rotated = await anonymous(`/v1/devices/${deviceId}/signed/rotate-key`, await rotateBody(install, deviceId, KEY_2));
    expect(rotated.status).toBe(200);
    const row = h.audit.find((entry) => entry.action === "device.rotate_key" && entry.cmuxId === deviceId);
    expect(row).toMatchObject({ actor: `device:${deviceId}`, ownerActor: "user:user_ada", outcome: "ok" });
  });

  it("credential calls keep the caller as the actor and no owner", async () => {
    await setup();
    await meshWithVm(A);
    const row = h.audit.find((entry) => entry.action === "acl.apply");
    expect(row?.actor).toMatch(/^key:vmk_/u);
    expect(row?.ownerActor).toBeNull();
  });
});

describe("G1: Stack team-membership webhook (cx-0op.6)", () => {
  it("removes every device the user enrolled in that team at once, by the recorded tunnel ids, and leaves others alone", async () => {
    await setup();
    for (const user of ["user_ada", "user_bob"]) h.addMember(A, user);
    h.addMember(B, "user_ada");
    const mesh = await meshWithVm(A);
    const otherTeam = await meshWithVm(B);
    const laptop = await makeInstallKey();
    const headless = await makeInstallKey();
    const bobs = await makeInstallKey();
    const adaB = await makeInstallKey();
    const ada1 = await sessionEnroll(A, "user_ada", mesh.meshId, laptop, KEY_1);
    const ada2 = await codeEnroll(A, "user_ada", mesh.meshId, headless, KEY_2);
    const bob = await sessionEnroll(A, "user_bob", mesh.meshId, bobs, KEY_3);
    const adaInB = await sessionEnroll(B, "user_ada", otherTeam.meshId, adaB, KEY_4);
    // Warm the shared cache: Ada's headless device is in use.
    expect((await signedPeers(headless, ada2.deviceId)).status).toBe(200);
    const deletesBefore = tunnelDeletes().length;

    h.removeMember(A, "user_ada");
    const response = await h.stackWebhook(membershipDeleted(A, "user_ada"));
    expect(response.status).toBe(200);

    expect(tunnelDeletes().slice(deletesBefore).sort()).toEqual([ada1.upstreamTunnel, ada2.upstreamTunnel].sort());
    expect(h.mesh.tunnels.has(ada1.upstreamTunnel)).toBe(false);
    expect(h.mesh.tunnels.has(ada2.upstreamTunnel)).toBe(false);
    expect(h.mesh.tunnels.has(bob.upstreamTunnel)).toBe(true);
    expect(h.mesh.tunnels.has(adaInB.upstreamTunnel)).toBe(true);
    // At once, although the cache held a fresh "member" answer for Ada.
    expect((await signedPeers(headless, ada2.deviceId)).status).toBe(404);
    expect((await call(`/v1/devices/${ada1.deviceId}`, mesh.admin)).status).toBe(404);
    expect((await call(`/v1/devices/${bob.deviceId}`, mesh.admin)).status).toBe(200);
    expect((await call(`/v1/devices/${adaInB.deviceId}`, otherTeam.admin)).status).toBe(200);
    // No provider rule names a removed device's tunnel any more.
    for (const rule of h.mesh.rules.values()) expect([ada1.upstreamTunnel, ada2.upstreamTunnel]).not.toContain(rule.source["tunnelId"]);
    const revoked = h.audit.filter((entry) => entry.action === "device.revoke");
    expect(revoked.map((entry) => entry.cmuxId).sort()).toEqual([ada1.deviceId, ada2.deviceId].sort());
    for (const entry of revoked) expect(entry).toMatchObject({ tenantId: A, actor: "system:stack-membership-webhook", ownerActor: "user:user_ada", outcome: "ok" });
  });

  it("invalidates the cached membership: the user's next session call asks Stack again and is refused", async () => {
    await setup();
    h.addMember(A, "user_ada");
    const headers = await session(A, "user_ada");
    expect((await call("/v1/meshes", headers)).status).toBe(200);
    h.removeMember(A, "user_ada");
    expect((await h.stackWebhook(membershipDeleted(A, "user_ada"))).status).toBe(200);
    const asked = h.stackMembershipCalls.length;
    expect((await call("/v1/meshes", headers)).status).toBe(403);
    expect(h.stackMembershipCalls.length).toBe(asked + 1);
  });

  it("is idempotent: a retried delivery (same message id) and a duplicate event do nothing more", async () => {
    await setup();
    h.addMember(A, "user_ada");
    const mesh = await meshWithVm(A);
    await sessionEnroll(A, "user_ada", mesh.meshId, await makeInstallKey(), KEY_1);
    h.removeMember(A, "user_ada");
    expect((await h.stackWebhook(membershipDeleted(A, "user_ada"), { id: "msg_retry" })).status).toBe(200);
    const calls = h.upstreamRequests.length;
    const audits = h.audit.length;
    const retry = await h.stackWebhook(membershipDeleted(A, "user_ada"), { id: "msg_retry" });
    expect(retry.status).toBe(200);
    expect((await json(retry))["duplicate"]).toBe(true);
    expect(h.upstreamRequests.length).toBe(calls);
    expect(h.audit.length).toBe(audits);
    // A second message for the same removal finds no device left.
    expect((await h.stackWebhook(membershipDeleted(A, "user_ada"), { id: "msg_other" })).status).toBe(200);
    expect(tunnelDeletes()).toHaveLength(1);
  });

  it("refuses unsigned, wrongly signed and stale deliveries without changing anything", async () => {
    await setup();
    h.addMember(A, "user_ada");
    const mesh = await meshWithVm(A);
    const device = await sessionEnroll(A, "user_ada", mesh.meshId, await makeInstallKey(), KEY_1);
    const event = membershipDeleted(A, "user_ada");
    const wrongSecret = `whsec_${btoa("another-secret-of-32-bytes-long!")}`;
    expect((await h.stackWebhook(event, { secret: wrongSecret })).status).toBe(401);
    expect((await h.stackWebhook(event, { signature: "v1,AAAA" })).status).toBe(401);
    expect((await h.stackWebhook(event, { timestampSeconds: Math.floor(Date.now() / 1000) - 600 })).status).toBe(401);
    const unsigned = await h.request("/v1/webhooks/stack", { "content-type": "application/json" }, { method: "POST", body: event });
    expect(unsigned.status).toBe(401);
    expect(tunnelDeletes()).toHaveLength(0);
    expect(h.mesh.tunnels.has(device.upstreamTunnel)).toBe(true);
  });

  it("acknowledges other event types without acting", async () => {
    await setup();
    h.addMember(A, "user_ada");
    const mesh = await meshWithVm(A);
    await sessionEnroll(A, "user_ada", mesh.meshId, await makeInstallKey(), KEY_1);
    const response = await h.stackWebhook({ type: "team_membership.created", data: { team_id: A, user_id: "user_ada" } });
    expect(response.status).toBe(200);
    expect(tunnelDeletes()).toHaveLength(0);
  });

  it("answers 503 'not configured' when STACK_WEBHOOK_SECRET is absent, and acts on nothing", async () => {
    await setup({});
    h.addMember(A, "user_ada");
    const mesh = await meshWithVm(A);
    await sessionEnroll(A, "user_ada", mesh.meshId, await makeInstallKey(), KEY_1);
    const response = await h.stackWebhook(membershipDeleted(A, "user_ada"), { secret: SECRET });
    expect(response.status).toBe(503);
    expect(str((await json(response))["message"])).toMatch(/not configured/u);
    expect(tunnelDeletes()).toHaveLength(0);
  });
});

/** A short real pause, so times recorded before and after it differ (millisecond clocks). */
const pause = () => new Promise((resolve) => setTimeout(resolve, 5));
const userDeleted = (user: string, teams: ReadonlyArray<string>) => ({ type: "user.deleted", data: { id: user, teams: teams.map((id) => ({ id })) } });

describe("G1: retries after a re-add (cx-0op.6)", () => {
  /** Ada enrolls `old`, is removed, and the first delivery of the removal fails at the provider (503). */
  const failedRemoval = async (messageId: string) => {
    h.addMember(A, "user_ada");
    const mesh = await meshWithVm(A);
    const old = await sessionEnroll(A, "user_ada", mesh.meshId, await makeInstallKey(), KEY_1);
    h.removeMember(A, "user_ada");
    h.mesh.failTunnelDeletes(500);
    expect((await h.stackWebhook(membershipDeleted(A, "user_ada"), { id: messageId })).status).toBe(503);
    h.mesh.failTunnelDeletes(null);
    expect(h.mesh.tunnels.has(old.upstreamTunnel)).toBe(true);
    await pause();
    return { mesh, old };
  };

  it("re-added before the retry: the retry still revokes the device from before the removal and keeps the new one", async () => {
    await setup();
    const { mesh, old } = await failedRemoval("msg_readd");
    h.addMember(A, "user_ada");
    const fresh = await sessionEnroll(A, "user_ada", mesh.meshId, await makeInstallKey(), KEY_2);
    const asked = h.stackMembershipCalls.length;

    const retry = await h.stackWebhook(membershipDeleted(A, "user_ada"), { id: "msg_readd" });
    expect(retry.status).toBe(200);
    // The webhook never asks Stack.
    expect(h.stackMembershipCalls.length).toBe(asked);
    const body = await json(retry);
    expect(body["skipped"]).toBeUndefined();
    expect(body["devicesRevoked"]).toBe(1);
    // A removal cuts the devices that existed then (an admin cutting a lost laptop); the re-add does not bring them back.
    expect(h.mesh.tunnels.has(old.upstreamTunnel)).toBe(false);
    expect((await call(`/v1/devices/${old.deviceId}`, mesh.admin)).status).toBe(404);
    expect(h.mesh.tunnels.has(fresh.upstreamTunnel)).toBe(true);
    expect((await call(`/v1/devices/${fresh.deviceId}`, mesh.admin)).status).toBe(200);
    // The re-added user still works: the new device's signed requests and sessions pass.
    expect((await call("/v1/meshes", await session(A, "user_ada"))).status).toBe(200);
    // Processed: the next retry is a duplicate.
    expect((await json(await h.stackWebhook(membershipDeleted(A, "user_ada"), { id: "msg_readd" })))["duplicate"]).toBe(true);
  });

  it("re-added and removed again before the retry, with no cached answer: the retry revokes only devices from before its event", async () => {
    await setup();
    const { mesh, old } = await failedRemoval("msg_first");
    h.addMember(A, "user_ada");
    const fresh = await sessionEnroll(A, "user_ada", mesh.meshId, await makeInstallKey(), KEY_2);
    await pause();
    h.removeMember(A, "user_ada");
    // The positive answer from the re-add expired (60 s): Stack is asked and says "not a member".
    h.membershipCache.rows.clear();

    const retry = await h.stackWebhook(membershipDeleted(A, "user_ada"), { id: "msg_first" });
    expect(retry.status).toBe(200);
    expect(h.mesh.tunnels.has(old.upstreamTunnel)).toBe(false);
    expect(h.mesh.tunnels.has(fresh.upstreamTunnel)).toBe(true);
    expect((await call(`/v1/devices/${old.deviceId}`, mesh.admin)).status).toBe(404);
    expect((await call(`/v1/devices/${fresh.deviceId}`, mesh.admin)).status).toBe(200);
    // The second removal's own event revokes the new device.
    expect((await h.stackWebhook(membershipDeleted(A, "user_ada"), { id: "msg_second" })).status).toBe(200);
    expect(h.mesh.tunnels.has(fresh.upstreamTunnel)).toBe(false);
  });

  it("re-added after the retry: a late redelivery of the old event (its record lost) keeps the new device, created after the event", async () => {
    await setup();
    const { mesh, old } = await failedRemoval("msg_late");
    expect((await h.stackWebhook(membershipDeleted(A, "user_ada"), { id: "msg_late" })).status).toBe(200);
    expect(h.mesh.tunnels.has(old.upstreamTunnel)).toBe(false);
    await pause();
    h.addMember(A, "user_ada");
    const fresh = await sessionEnroll(A, "user_ada", mesh.meshId, await makeInstallKey(), KEY_2);
    // The processed record and the cached answer are gone: only the event time and Stack decide.
    h.webhookDeliveries.deliveries.clear();
    h.membershipCache.rows.clear();
    const asked = h.stackMembershipCalls.length;

    const late = await h.stackWebhook(membershipDeleted(A, "user_ada"), { id: "msg_late" });
    expect(late.status).toBe(200);
    expect((await json(late))["devicesRevoked"]).toBe(0);
    expect(h.stackMembershipCalls.length).toBe(asked);
    expect(h.mesh.tunnels.has(fresh.upstreamTunnel)).toBe(true);
    expect((await call(`/v1/devices/${fresh.deviceId}`, mesh.admin)).status).toBe(200);
  });
});

describe("G1: events with nothing to revoke are a recorded 200 (staging: team 94eb2b2b got 503)", () => {
  it("a team outside the mesh allowlist, with no devices, whose user Stack cannot answer for: 200, recorded, retry a duplicate", async () => {
    await setup();
    h.failStackFor("user_throwaway");
    const event = membershipDeleted("team_personal_throwaway", "user_throwaway");
    const first = await h.stackWebhook(event, { id: "msg_personal_team" });
    expect(first.status).toBe(200);
    expect((await json(first))["devicesRevoked"]).toBe(0);
    expect(h.webhookDeliveries.deliveries.has("msg_personal_team")).toBe(true);
    expect((await json(await h.stackWebhook(event, { id: "msg_personal_team" })))["duplicate"]).toBe(true);
    expect(tunnelDeletes()).toHaveLength(0);
  });

  it("an allowlisted team: the device is revoked even when Stack cannot answer for the user", async () => {
    await setup();
    h.addMember(A, "user_ada");
    const mesh = await meshWithVm(A);
    const device = await sessionEnroll(A, "user_ada", mesh.meshId, await makeInstallKey(), KEY_1);
    h.removeMember(A, "user_ada");
    h.failStackFor("user_ada");
    const response = await h.stackWebhook(membershipDeleted(A, "user_ada"));
    expect(response.status).toBe(200);
    expect(h.mesh.tunnels.has(device.upstreamTunnel)).toBe(false);
  });
});

describe("G1: user.deleted (cx-0op.6)", () => {
  it("revokes the user's devices in every tenant, even one the event does not list, without asking Stack about the deleted user", async () => {
    await setup();
    for (const user of ["user_ada", "user_bob"]) h.addMember(A, user);
    h.addMember(B, "user_ada");
    const meshA = await meshWithVm(A);
    const meshB = await meshWithVm(B);
    const headless = await makeInstallKey();
    const ada1 = await sessionEnroll(A, "user_ada", meshA.meshId, await makeInstallKey(), KEY_1);
    const ada2 = await codeEnroll(A, "user_ada", meshA.meshId, headless, KEY_2);
    const adaB = await sessionEnroll(B, "user_ada", meshB.meshId, await makeInstallKey(), KEY_3);
    const bob = await sessionEnroll(A, "user_bob", meshA.meshId, await makeInstallKey(), KEY_4);
    const sessionB = await session(B, "user_ada");
    expect((await call("/v1/meshes", sessionB)).status).toBe(200);
    expect((await signedPeers(headless, ada2.deviceId)).status).toBe(200);
    h.removeMember(A, "user_ada");
    h.removeMember(B, "user_ada");
    const asked = h.stackMembershipCalls.length;

    // Team B is not listed: the Worker's own device rows find it.
    const response = await h.stackWebhook(userDeleted("user_ada", [A]), { id: "msg_user_deleted" });
    expect(response.status).toBe(200);
    expect(h.stackMembershipCalls.length).toBe(asked);
    for (const gone of [ada1, ada2, adaB]) expect(h.mesh.tunnels.has(gone.upstreamTunnel)).toBe(false);
    expect(h.mesh.tunnels.has(bob.upstreamTunnel)).toBe(true);
    expect((await signedPeers(headless, ada2.deviceId)).status).toBe(404);
    expect((await call(`/v1/devices/${adaB.deviceId}`, meshB.admin)).status).toBe(404);
    expect((await call(`/v1/devices/${bob.deviceId}`, meshA.admin)).status).toBe(200);
    const revoked = h.audit.filter((entry) => entry.action === "device.revoke");
    expect(revoked.map((entry) => entry.cmuxId).sort()).toEqual([ada1.deviceId, ada2.deviceId, adaB.deviceId].sort());
    for (const entry of revoked) expect(entry).toMatchObject({ actor: "system:stack-user-deleted-webhook", ownerActor: "user:user_ada", outcome: "ok" });
    // Every tenant's cached "member" is gone: the next session call asks Stack.
    const before = h.stackMembershipCalls.length;
    expect((await call("/v1/meshes", sessionB)).status).toBe(403);
    expect(h.stackMembershipCalls.length).toBe(before + 1);
  });

  it("is idempotent: a retry is a duplicate and another message for the same deletion changes nothing", async () => {
    await setup();
    h.addMember(A, "user_ada");
    const mesh = await meshWithVm(A);
    await sessionEnroll(A, "user_ada", mesh.meshId, await makeInstallKey(), KEY_1);
    h.removeMember(A, "user_ada");
    expect((await h.stackWebhook(userDeleted("user_ada", [A]), { id: "msg_ud" })).status).toBe(200);
    expect(tunnelDeletes()).toHaveLength(1);
    const calls = h.upstreamRequests.length;
    const audits = h.audit.length;
    const retry = await h.stackWebhook(userDeleted("user_ada", [A]), { id: "msg_ud" });
    expect((await json(retry))["duplicate"]).toBe(true);
    expect(h.upstreamRequests.length).toBe(calls);
    expect(h.audit.length).toBe(audits);
    expect((await h.stackWebhook(userDeleted("user_ada", [A]), { id: "msg_ud_2" })).status).toBe(200);
    expect(tunnelDeletes()).toHaveLength(1);
  });

  it("refuses a signed user.deleted body of the wrong shape with 400", async () => {
    await setup();
    expect((await h.stackWebhook({ type: "user.deleted", data: { user_id: "user_ada" } })).status).toBe(400);
  });
});

describe("G1: delivery diagnostics (staging 09:13:04Z delivery left no row)", () => {
  /** Every console line the Worker wrote while `run` ran. */
  const captureLogs = async (run: () => Promise<void>) => {
    const lines: string[] = [];
    const spies = (["log", "info", "warn", "error", "debug"] as const).map((method) =>
      vi.spyOn(console, method).mockImplementation((...args: unknown[]) => void lines.push(args.map(String).join(" "))),
    );
    try {
      await run();
    } finally {
      for (const spy of spies) spy.mockRestore();
    }
    return lines.filter((line) => line.includes("stack webhook"));
  };

  it("accepts a rotation header with two full signatures where only the second matches", async () => {
    await setup();
    h.addMember(A, "user_ada");
    const mesh = await meshWithVm(A);
    const device = await sessionEnroll(A, "user_ada", mesh.meshId, await makeInstallKey(), KEY_1);
    h.removeMember(A, "user_ada");
    const event = membershipDeleted(A, "user_ada");
    const id = "msg_rotation";
    const timestamp = String(Math.floor(Date.now() / 1000));
    const content = `${id}.${timestamp}.${JSON.stringify(event)}`;
    const old = await signWebhookContent(Redacted.make(`whsec_${btoa("the-previous-secret-of-32-bytes!")}`), content);
    const current = await signWebhookContent(Redacted.make(SECRET), content);
    const response = await h.stackWebhook(event, { id, timestampSeconds: Number(timestamp), signature: `v1,${old ?? ""} v1,${current ?? ""}` });
    expect(response.status).toBe(200);
    expect(h.mesh.tunnels.has(device.upstreamTunnel)).toBe(false);
  });

  it("logs the reason of every refusal and failure, without the secret, the signature or the body", async () => {
    await setup();
    const event = membershipDeleted(A, "user_ada");
    const lines = await captureLogs(async () => {
      expect((await h.stackWebhook(event, { signature: "v1,AAAA" })).status).toBe(401);
      expect((await h.stackWebhook(event, { timestampSeconds: Math.floor(Date.now() / 1000) - 600 })).status).toBe(401);
      expect((await h.stackWebhook({ type: "team_membership.deleted", data: { team: A } }, { id: "msg_shape" })).status).toBe(400);
      expect((await h.request("/v1/webhooks/stack", { "svix-id": "msg_json" }, { method: "POST", body: "x" })).status).toBe(401);
    });
    expect(lines.some((line) => /status=401/u.test(line) && /reason=signature/u.test(line))).toBe(true);
    expect(lines.some((line) => /status=401/u.test(line) && /reason=stale/u.test(line))).toBe(true);
    expect(lines.some((line) => /status=400/u.test(line) && /reason=data_shape/u.test(line) && /eventType=team_membership\.deleted/u.test(line) && /messageId=msg_shape/u.test(line))).toBe(true);
    for (const line of lines) {
      expect(line).not.toContain(SECRET.slice(6, 20));
      expect(line).not.toContain("user_ada");
      expect(line).not.toContain("AAAA");
    }
  });

  it("logs a 503 when the first-receipt record fails (migration 0008 missing), and the delivery is retried", async () => {
    await setup();
    h.addMember(A, "user_ada");
    const mesh = await meshWithVm(A);
    await sessionEnroll(A, "user_ada", mesh.meshId, await makeInstallKey(), KEY_1);
    h.removeMember(A, "user_ada");
    const working = h.webhookDeliveries.service.firstSeen;
    Object.assign(h.webhookDeliveries.service, { firstSeen: () => Effect.fail(new StoreError({ operation: "webhook.firstSeen", cause: "relation does not exist" })) });
    const lines = await captureLogs(async () => {
      expect((await h.stackWebhook(membershipDeleted(A, "user_ada"), { id: "msg_no_0008" })).status).toBe(503);
    });
    expect(lines.some((line) => /status=503/u.test(line) && /reason=first_seen_store/u.test(line) && /messageId=msg_no_0008/u.test(line))).toBe(true);
    expect(tunnelDeletes()).toHaveLength(0);
    Object.assign(h.webhookDeliveries.service, { firstSeen: working });
    const processed = await captureLogs(async () => {
      expect((await h.stackWebhook(membershipDeleted(A, "user_ada"), { id: "msg_no_0008" })).status).toBe(200);
    });
    expect(processed.some((line) => /status=200/u.test(line) && /outcome=revoked/u.test(line) && /devicesRevoked=1/u.test(line))).toBe(true);
  });
});

describe("one writer per mesh (DESIGN.md 4.1, M4 decision)", () => {
  it("an enroll whose reconcile started from the old ACL cannot leave a rule the concurrent apply removed", async () => {
    await setup();
    const mesh = await meshWithVm(A);
    await call(`/v1/meshes/${mesh.meshId}/devices`, mesh.admin, "POST", await enrollBody(await makeInstallKey(), mesh.meshId, { name: "one", wgPublicKey: KEY_1 }));
    expect(h.mesh.rules.size).toBe(1);
    // The enroll's rule create (from ACL v1) stalls at the provider while v2 (no rules) is applied.
    const release = h.mesh.holdRuleCreates();
    const enroll = call(`/v1/meshes/${mesh.meshId}/devices`, mesh.admin, "POST", await enrollBody(await makeInstallKey(), mesh.meshId, { name: "two", wgPublicKey: KEY_2 }));
    await h.mesh.ruleCreateHeld();
    const apply = call(`/v1/meshes/${mesh.meshId}/acl`, mesh.admin, "PUT", { expectedVersion: 1, rules: [] });
    await new Promise((resolve) => setTimeout(resolve, 100));
    release();
    expect((await enroll).status).toBe(201);
    expect((await apply).status).toBe(200);
    expect(h.mesh.rules.size).toBe(0);
  });
});
