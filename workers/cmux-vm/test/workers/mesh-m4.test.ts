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
 * 4. One writer per mesh: a reconcile planned from an old ACL version cannot
 *    re-open a rule a concurrent apply removed.
 */
import { afterEach, describe, expect, it } from "vitest";
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
