/**
 * Agent keys and per-VM client sessions (cloud agents start and clean up their
 * own sandboxes). An agent key is a short-lived API key confined to the VMs it
 * creates (label cmux.agent=<key id>), with a live-VM count and $/h budget.
 * A client session is a provider identity token for exactly one VM and one
 * Linux user; it is revoked when the VM is deleted, and the reaper deletes an
 * expired or revoked agent's VMs and identities. The team's provider key never
 * leaves the Worker.
 */
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { bearer } from "../support/endpoints.ts";
import { makeHarness } from "../support/harness.ts";

type Harness = Awaited<ReturnType<typeof makeHarness>>;

const TENANT_A = "team_alpha";
const TENANT_B = "team_bravo";
const UPSTREAM_KEY = "upstream-test-key";

let h: Harness;
beforeEach(async () => {
  h = await makeHarness();
});
afterEach(async () => {
  await h.dispose();
});

interface AgentKeyBody {
  readonly id: string;
  readonly key: string;
  readonly labels: Readonly<Record<string, string>>;
  readonly scopes: ReadonlyArray<string>;
  readonly expiresAt: string;
  readonly maxVms: number;
  readonly maxUsdPerHour: number;
}

interface VmBody {
  readonly id: string;
  readonly labels: Readonly<Record<string, string>>;
}

const issue = async (issuer: string, body: Record<string, unknown> = {}) => {
  const response = await h.request("/v1/agent-keys", bearer(issuer), { method: "POST", body: { name: "a426", ...body } });
  expect(response.status).toBe(201);
  return response.json<AgentKeyBody>();
};

const createVm = async (secret: string, body: Record<string, unknown> = {}) =>
  h.request("/v1/vms", bearer(secret), { method: "POST", body });

const created = async (secret: string, body: Record<string, unknown> = {}) => {
  const response = await createVm(secret, body);
  expect(response.status).toBe(201);
  return response.json<VmBody>();
};

describe("issuing an agent key", () => {
  it("returns the key once, confined to its own label, with the default budget", async () => {
    const issuer = await h.addKey(TENANT_A, ["vm:read", "vm:write", "vm:exec"]);
    const agent = await issue(issuer);
    expect(agent.key).toMatch(/^cmuxvm_sk_/);
    expect(agent.labels).toEqual({ "cmux.agent": agent.id });
    expect(agent.scopes).toEqual(["vm:read", "vm:write", "vm:exec"]);
    expect(agent.maxVms).toBe(5);
    expect(agent.maxUsdPerHour).toBe(2);
    const ttl = Date.parse(agent.expiresAt) - Date.now();
    expect(ttl).toBeGreaterThan(3 * 3600_000);
    expect(ttl).toBeLessThanOrEqual(4 * 3600_000);
    expect(h.audit).toContainEqual(expect.objectContaining({ tenantId: TENANT_A, action: "agentkey.create", cmuxId: agent.id, outcome: "ok" }));
  });

  it("needs vm:write and never grants a scope the issuer lacks", async () => {
    const reader = await h.addKey(TENANT_A, ["vm:read"]);
    expect((await h.request("/v1/agent-keys", bearer(reader), { method: "POST", body: { name: "x" } })).status).toBe(403);
    const writer = await h.addKey(TENANT_A, ["vm:read", "vm:write"]);
    const refused = await h.request("/v1/agent-keys", bearer(writer), { method: "POST", body: { name: "x", scopes: ["vm:read", "vm:write", "vm:exec"] } });
    expect(refused.status).toBe(403);
  });

  it("refuses scopes outside the agent set and budgets beyond the caps", async () => {
    const issuer = await h.addKey(TENANT_A, ["vm:read", "vm:write", "vm:exec", "vm:network"]);
    const bad = [
      { scopes: ["vm:read", "vm:write", "vm:network"] },
      { maxVms: 0 },
      { maxVms: 21 },
      { maxUsdPerHour: 0 },
      { maxUsdPerHour: 51 },
      { ttlSeconds: 30 },
      { ttlSeconds: 86_401 },
    ];
    for (const body of bad) {
      const response = await h.request("/v1/agent-keys", bearer(issuer), { method: "POST", body: { name: "x", ...body } });
      expect(response.status, JSON.stringify(body)).toBe(400);
    }
  });

  it("never outlives an expiring issuer", async () => {
    const issuer = await h.addKey(TENANT_A, ["vm:read", "vm:write"], { expiresAt: new Date(Date.now() + 600_000) });
    const agent = await issue(issuer, { ttlSeconds: 3600 });
    expect(Date.parse(agent.expiresAt)).toBeLessThanOrEqual(Date.now() + 600_000);
  });

  it("refuses an agent key or an allowlisted key as issuer", async () => {
    const issuer = await h.addKey(TENANT_A, ["vm:read", "vm:write"]);
    const agent = await issue(issuer);
    expect((await h.request("/v1/agent-keys", bearer(agent.key), { method: "POST", body: { name: "child" } })).status).toBe(403);
    const { vmId } = h.addVm(TENANT_A);
    const narrow = await h.addKey(TENANT_A, ["vm:read", "vm:write"], { allowlist: [vmId] });
    expect((await h.request("/v1/agent-keys", bearer(narrow), { method: "POST", body: { name: "x" } })).status).toBe(403);
  });

  it("lets a team member's session issue one", async () => {
    h.addMember(TENANT_A, "user_1");
    const token = await h.sessionToken("user_1");
    const response = await h.request("/v1/agent-keys", { ...bearer(token), "x-cmux-team-id": TENANT_A }, { method: "POST", body: { name: "x" } });
    expect(response.status).toBe(201);
  });

  it("carries a service issuer's labels into the agent's confinement", async () => {
    const service = await h.addServiceKey();
    const response = await h.request("/v1/agent-keys", { ...bearer(service), "x-cmux-team-id": TENANT_A }, { method: "POST", body: { name: "x" } });
    expect(response.status).toBe(201);
    const agent = await response.json<AgentKeyBody>();
    expect(agent.labels).toEqual({ role: "chief", "cmux.agent": agent.id });
    const vm = await created(agent.key);
    expect(vm.labels).toEqual({ role: "chief", "cmux.agent": agent.id });
  });
});

describe("an agent's sandboxes", () => {
  it("labels what it creates, sees and deletes only those", async () => {
    const issuer = await h.addKey(TENANT_A, ["vm:read", "vm:write", "vm:exec"]);
    const first = await issue(issuer);
    const second = await issue(issuer);
    const team = h.addVm(TENANT_A);

    const vm = await created(first.key, { labels: { purpose: "test" } });
    expect(vm.labels).toEqual({ purpose: "test", "cmux.agent": first.id });

    const listed = await (await h.request("/v1/vms", bearer(first.key))).json<{ items: ReadonlyArray<VmBody> }>();
    expect(listed.items.map((item) => item.id)).toEqual([vm.id]);

    // Another agent of the same team, and a VM the agent did not create, are as absent as another tenant's.
    expect((await h.request(`/v1/vms/${vm.id}`, bearer(second.key))).status).toBe(404);
    expect((await h.request(`/v1/vms/${vm.id}/exec`, bearer(second.key), { method: "POST", body: { command: "whoami" } })).status).toBe(404);
    expect((await h.request(`/v1/vms/${vm.id}`, bearer(second.key), { method: "DELETE" })).status).toBe(404);
    expect((await h.request(`/v1/vms/${team.vmId}`, bearer(first.key))).status).toBe(404);

    // The fake provider boots VMs as "starting"; exec needs a running one.
    const upstreamVm = h.upstream.vms.get(h.resources.find((row) => row.cmuxId === vm.id)?.upstreamId ?? "");
    if (upstreamVm !== undefined) upstreamVm.state = "running";
    expect((await h.request(`/v1/vms/${vm.id}/exec`, bearer(first.key), { method: "POST", body: { command: "whoami" } })).status).toBe(200);
    expect((await h.request(`/v1/vms/${vm.id}`, bearer(first.key), { method: "DELETE" })).status).toBe(204);
  });

  it("refuses a label that impersonates another agent", async () => {
    const issuer = await h.addKey(TENANT_A, ["vm:read", "vm:write"]);
    const first = await issue(issuer);
    const second = await issue(issuer);
    expect((await createVm(first.key, { labels: { "cmux.agent": second.id } })).status).toBe(403);
  });

  it("stops at the live-VM budget and frees it on delete", async () => {
    const issuer = await h.addKey(TENANT_A, ["vm:read", "vm:write"]);
    const agent = await issue(issuer, { maxVms: 1 });
    const vm = await created(agent.key);
    const over = await createVm(agent.key);
    expect(over.status).toBe(429);
    expect(await over.json()).toMatchObject({ budget: "agent_vms" });
    expect((await h.request(`/v1/vms/${vm.id}`, bearer(agent.key), { method: "DELETE" })).status).toBe(204);
    await created(agent.key);
  });

  it("stops at the $/h budget, counting the requested size", async () => {
    const issuer = await h.addKey(TENANT_A, ["vm:read", "vm:write"]);
    // The default 4 vCPU / 8 GiB VM is estimated at 0.26 USD/h.
    const agent = await issue(issuer, { maxUsdPerHour: 0.6 });
    await created(agent.key);
    await created(agent.key);
    const over = await createVm(agent.key);
    expect(over.status).toBe(429);
    expect(await over.json()).toMatchObject({ budget: "agent_usd_per_hour" });
    const big = await issue(issuer, { maxUsdPerHour: 1 });
    expect((await createVm(big.key, { resources: { vcpus: 16, memoryMib: 32768 } })).status).toBe(429);
  });

  it("stops working when it expires or is revoked", async () => {
    const issuer = await h.addKey(TENANT_A, ["vm:read", "vm:write"]);
    const agent = await issue(issuer);
    expect((await h.request(`/v1/agent-keys/${agent.id}`, bearer(issuer), { method: "DELETE" })).status).toBe(204);
    expect((await h.request("/v1/vms", bearer(agent.key))).status).toBe(401);
  });

  it("lets the agent revoke itself, but not a sibling", async () => {
    const issuer = await h.addKey(TENANT_A, ["vm:read", "vm:write"]);
    const first = await issue(issuer);
    const second = await issue(issuer);
    expect((await h.request(`/v1/agent-keys/${second.id}`, bearer(first.key), { method: "DELETE" })).status).toBe(404);
    expect((await h.request(`/v1/agent-keys/${first.id}`, bearer(first.key), { method: "DELETE" })).status).toBe(204);
    expect((await h.request("/v1/vms", bearer(first.key))).status).toBe(401);
  });

  it("keeps another tenant's agent keys unrevocable", async () => {
    const issuer = await h.addKey(TENANT_A, ["vm:read", "vm:write"]);
    const agent = await issue(issuer);
    const other = await h.addKey(TENANT_B, ["vm:read", "vm:write", "admin"]);
    expect((await h.request(`/v1/agent-keys/${agent.id}`, bearer(other), { method: "DELETE" })).status).toBe(404);
  });
});

describe("client sessions", () => {
  interface SessionBody {
    readonly id: string;
    readonly token: string;
    readonly vmId: string;
    readonly providerVmId: string;
    readonly linuxUser: string;
    readonly apiBaseUrl: string;
    readonly ssh: { readonly host: string; readonly user: string };
  }

  const open = async (secret: string, vmId: string, body: Record<string, unknown> = {}) =>
    h.request(`/v1/vms/${vmId}/client-session`, bearer(secret), { method: "POST", body });

  it("mints a provider token for exactly this VM and the work user, never the team key", async () => {
    const issuer = await h.addKey(TENANT_A, ["vm:read", "vm:write", "vm:exec"]);
    const agent = await issue(issuer);
    const vm = await created(agent.key);
    const response = await open(agent.key, vm.id);
    expect(response.status).toBe(201);
    const text = await response.text();
    expect(text).not.toContain(UPSTREAM_KEY);
    const session: SessionBody = JSON.parse(text);
    const upstreamVmId = h.resources.find((row) => row.cmuxId === vm.id)?.upstreamId;
    expect(session).toMatchObject({ vmId: vm.id, providerVmId: upstreamVmId, linuxUser: "ubuntu" });
    expect(session.ssh).toEqual({ host: "beta-ssh.freestyle.sh", user: `${upstreamVmId}+ubuntu` });
    expect(session.id).toMatch(/^vcs_/);
    expect(h.upstream.identityGrants(session.token)).toEqual([{ vmId: upstreamVmId, allowedLinuxUsers: ["ubuntu"] }]);
    expect(h.audit).toContainEqual(expect.objectContaining({ action: "vm.client_session", cmuxId: vm.id, outcome: "ok" }));
  });

  it("names another Linux user when asked, and refuses a malformed one", async () => {
    const issuer = await h.addKey(TENANT_A, ["vm:read", "vm:write", "vm:exec"]);
    const vm = await created(issuer);
    const session = await (await open(issuer, vm.id, { linuxUser: "cmux" })).json<SessionBody>();
    expect(session.linuxUser).toBe("cmux");
    expect((await open(issuer, vm.id, { linuxUser: "bad user" })).status).toBe(400);
  });

  it("needs vm:exec and ownership", async () => {
    const reader = await h.addKey(TENANT_A, ["vm:read", "vm:write"]);
    const vm = await created(reader);
    expect((await open(reader, vm.id)).status).toBe(403);
    const other = await h.addKey(TENANT_B, ["vm:read", "vm:write", "vm:exec"]);
    expect((await open(other, vm.id)).status).toBe(404);
    expect(h.upstream.identityCount()).toBe(0);
  });

  it("is revoked when its VM is deleted", async () => {
    const issuer = await h.addKey(TENANT_A, ["vm:read", "vm:write", "vm:exec"]);
    const vm = await created(issuer);
    const session = await (await open(issuer, vm.id)).json<SessionBody>();
    expect(h.upstream.tokenValid(session.token)).toBe(true);
    expect((await h.request(`/v1/vms/${vm.id}`, bearer(issuer), { method: "DELETE" })).status).toBe(204);
    expect(h.upstream.tokenValid(session.token)).toBe(false);
    expect(h.upstream.identityCount()).toBe(0);
  });

  it("can be revoked on its own", async () => {
    const issuer = await h.addKey(TENANT_A, ["vm:read", "vm:write", "vm:exec"]);
    const vm = await created(issuer);
    const session = await (await open(issuer, vm.id)).json<SessionBody>();
    const revoked = await h.request(`/v1/vms/${vm.id}/client-sessions/${session.id}`, bearer(issuer), { method: "DELETE" });
    expect(revoked.status).toBe(204);
    expect(h.upstream.tokenValid(session.token)).toBe(false);
    expect((await h.request(`/v1/vms/${vm.id}/client-sessions/${session.id}`, bearer(issuer), { method: "DELETE" })).status).toBe(204);
  });

  it("lists a VM's live sessions without tokens, in creation order, and drops revoked ones", async () => {
    const issuer = await h.addKey(TENANT_A, ["vm:read", "vm:write", "vm:exec"]);
    const vm = await created(issuer);
    const first = await (await open(issuer, vm.id)).json<SessionBody>();
    const second = await (await open(issuer, vm.id, { linuxUser: "cmux" })).json<SessionBody>();
    const listed = await h.request(`/v1/vms/${vm.id}/client-sessions`, bearer(issuer));
    expect(listed.status).toBe(200);
    const text = await listed.text();
    expect(text).not.toContain(first.token);
    expect(text).not.toContain(second.token);
    expect(text).not.toContain(UPSTREAM_KEY);
    const body: { sessions: ReadonlyArray<{ id: string; vmId: string; linuxUser: string; createdAt: string }> } = JSON.parse(text);
    expect(body.sessions.map((row) => row.id).sort()).toEqual([first.id, second.id].sort());
    expect(body.sessions.find((row) => row.id === second.id)).toMatchObject({ vmId: vm.id, linuxUser: "cmux" });
    await h.request(`/v1/vms/${vm.id}/client-sessions/${first.id}`, bearer(issuer), { method: "DELETE" });
    const after = await (await h.request(`/v1/vms/${vm.id}/client-sessions`, bearer(issuer))).json<{ sessions: ReadonlyArray<{ id: string }> }>();
    expect(after.sessions.map((row) => row.id)).toEqual([second.id]);
  });

  it("lists sessions only for an owned VM and with vm:exec", async () => {
    const reader = await h.addKey(TENANT_A, ["vm:read", "vm:write"]);
    const vm = await created(reader);
    expect((await h.request(`/v1/vms/${vm.id}/client-sessions`, bearer(reader))).status).toBe(403);
    const other = await h.addKey(TENANT_B, ["vm:read", "vm:write", "vm:exec"]);
    expect((await h.request(`/v1/vms/${vm.id}/client-sessions`, bearer(other))).status).toBe(404);
  });

  it("deletes the identity when the grant fails, leaving nothing behind", async () => {
    const issuer = await h.addKey(TENANT_A, ["vm:read", "vm:write", "vm:exec"]);
    const vm = await created(issuer);
    h.upstream.fail("grantVmPermission", 500);
    expect((await open(issuer, vm.id)).status).toBe(503);
    expect(h.upstream.identityCount()).toBe(0);
  });
});

describe("the reaper", () => {
  it("deletes an expired agent's VMs and identities, and nothing else", async () => {
    const issuer = await h.addKey(TENANT_A, ["vm:read", "vm:write", "vm:exec"]);
    const doomed = await issue(issuer);
    const alive = await issue(issuer);
    const team = h.addVm(TENANT_A);
    const a = await created(doomed.key);
    const b = await created(doomed.key);
    const keep = await created(alive.key);
    const session = await (await h.request(`/v1/vms/${a.id}/client-session`, bearer(doomed.key), { method: "POST", body: {} })).json<{ token: string }>();

    h.expireKey(doomed.id);
    const report = await h.reap();
    expect(report).toMatchObject({ agentKeys: 1, vmsDeleted: 2, identitiesRevoked: 1 });

    expect(h.isDeleted(a.id)).toBe(true);
    expect(h.isDeleted(b.id)).toBe(true);
    expect(h.isDeleted(keep.id)).toBe(false);
    expect(h.isDeleted(team.vmId)).toBe(false);
    expect(h.upstream.tokenValid(session.token)).toBe(false);
    expect(h.audit).toContainEqual(expect.objectContaining({ actor: "service:agent-reaper", action: "vm.delete", cmuxId: a.id, outcome: "ok" }));

    // Cleaned keys are not visited again.
    expect(await h.reap()).toMatchObject({ agentKeys: 0, vmsDeleted: 0 });
  });

  it("cleans up a revoked agent at once, and the reaper finishes what the revoke could not", async () => {
    const issuer = await h.addKey(TENANT_A, ["vm:read", "vm:write"]);
    const agent = await issue(issuer);
    const vm = await created(agent.key);
    h.upstream.fail("delete", 503);
    expect((await h.request(`/v1/agent-keys/${agent.id}`, bearer(issuer), { method: "DELETE" })).status).toBe(204);
    expect(h.isDeleted(vm.id)).toBe(false);
    expect(await h.reap()).toMatchObject({ agentKeys: 1, vmsDeleted: 1 });
    expect(h.isDeleted(vm.id)).toBe(true);
  });

  it("keeps a key whose VM it could not delete, and retries it", async () => {
    const issuer = await h.addKey(TENANT_A, ["vm:read", "vm:write"]);
    const agent = await issue(issuer);
    const vm = await created(agent.key);
    h.expireKey(agent.id);
    h.upstream.fail("delete", 503);
    expect(await h.reap()).toMatchObject({ agentKeys: 1, vmsDeleted: 0, failures: 1 });
    expect(await h.reap()).toMatchObject({ agentKeys: 1, vmsDeleted: 1, failures: 0 });
    expect(h.isDeleted(vm.id)).toBe(true);
  });

  it("revokes identities whose VM was deleted while the revoke failed", async () => {
    const issuer = await h.addKey(TENANT_A, ["vm:read", "vm:write", "vm:exec"]);
    const vm = await created(issuer);
    const session = await (await h.request(`/v1/vms/${vm.id}/client-session`, bearer(issuer), { method: "POST", body: {} })).json<{ token: string }>();
    h.upstream.fail("deleteIdentity", 503);
    expect((await h.request(`/v1/vms/${vm.id}`, bearer(issuer), { method: "DELETE" })).status).toBe(204);
    expect(h.upstream.tokenValid(session.token)).toBe(true);
    expect(await h.reap()).toMatchObject({ identitiesRevoked: 1 });
    expect(h.upstream.tokenValid(session.token)).toBe(false);
  });
});
