import { describe, expect, test } from "bun:test";
import {
  REFLECTION_PATHS,
  normalizeReflectionPath,
  reflectionIndex,
  reflectionIntegrations,
  reflectionMachine,
  reflectionOwner,
  reflectionPayload,
  reflectionPeerRoute,
  reflectionPeers,
  reflectionSize,
  type ReflectionContext,
} from "../services/vms/reflection";
import { requireVmPrincipal, vmPrincipalOwns } from "../services/vms/vmPrincipal";
import {
  vmPrincipalFailureResponse,
  vmPrincipalFailureStatus,
  type VmPrincipalRow,
} from "../services/vms/vmPrincipalContract";
import { ROUTE_TOKEN_HEADER, VM_ID_HEADER } from "../services/coderouter/routeTokenAuth";

// cmux Reflection: a machine learns about itself through the identity the edge
// injects (the VM-bound route token + x-cmux-vm-id), never through anything it
// claims. These tests cover the principal check and every payload the guest can
// read, with rows and an owner snapshot supplied directly (no database).

const SELF_ID = "11111111-2222-4333-8444-555555555555";
const PEER_ID = "22222222-2222-4333-8444-555555555555";
const OTHER_OWNER_ID = "33333333-2222-4333-8444-555555555555";
const DESTROYED_ID = "44444444-2222-4333-8444-555555555555";
const ADDRESSLESS_ID = "55555555-2222-4333-8444-555555555555";

function row(overrides: Partial<VmPrincipalRow> & { id: string }): VmPrincipalRow {
  return {
    userId: "user-1",
    billingTeamId: "team-1",
    billingPlanId: "pro",
    provider: "freestyle",
    providerVmId: `prov-${overrides.id.slice(0, 8)}`,
    displayName: null,
    slug: null,
    imageId: "sh-devbox-desktop",
    imageVersion: "2026-09-02-r4",
    status: "running",
    createdAt: new Date("2026-09-06T00:00:00Z"),
    providerMetadata: {},
    ...overrides,
  };
}

const self = row({
  id: SELF_ID,
  slug: "brave-otter",
  displayName: "build box",
  providerMetadata: {
    networkIpv4: "10.7.0.5",
    networkIpv6: "fd00:7::5",
    cmuxResourceReservation: { vcpus: 5, memoryMb: 20480, diskMb: 32768 },
  },
});
const peer = row({ id: PEER_ID, slug: "vivid-newt", providerMetadata: { networkIpv6: "fd00:7::9" } });
const addressless = row({ id: ADDRESSLESS_ID, slug: "quiet-fox", status: "paused" });
const destroyed = row({ id: DESTROYED_ID, slug: "gone-goose", status: "destroyed", providerMetadata: { networkIpv6: "fd00:7::d" } });
const otherOwner = row({ id: OTHER_OWNER_ID, slug: "someone-elses", userId: "user-9", billingTeamId: "team-9", providerMetadata: { networkIpv4: "10.9.0.2" } });

const context: ReflectionContext = {
  self,
  owner: { userId: "user-1", email: "austin@example.com", displayName: "Austin", teamId: "team-1", planId: "pro" },
  siblings: [self, peer, addressless, destroyed, otherOwner],
  aliasOrigin: "https://coderouter.cmux.internal",
  reflectionOrigin: "https://reflection.cmux.internal",
  hasDesktop: true,
};

function guestRequest(headers: Record<string, string> = {}): Request {
  return new Request("https://coderouter.dev/api/vm/reflection", {
    headers: {
      authorization: "Bearer cmux-vm-edge-placeholder",
      [ROUTE_TOKEN_HEADER]: "crt_edge-injected",
      [VM_ID_HEADER]: SELF_ID,
      ...headers,
    },
  });
}

const boundIdentity = async (token: string) => token === "crt_edge-injected"
  ? { teamId: "team-1", stackUserId: "user-1", vmId: SELF_ID }
  : null;

describe("requireVmPrincipal", () => {
  test("accepts the edge-injected VM-bound token for a live machine the owner has", async () => {
    const result = await requireVmPrincipal(guestRequest(), {
      authenticate: boundIdentity,
      loadVm: async (id) => (id === SELF_ID ? self : null),
    });
    expect(result.ok).toBe(true);
    if (!result.ok) throw new Error(result.reason);
    expect(result.principal.vm.id).toBe(SELF_ID);
    expect(result.principal.userId).toBe("user-1");
    expect(result.principal.teamId).toBe("team-1");
  });

  test("rejects requests without a machine credential, a forged VM id, and an unbound token", async () => {
    const noToken = new Request("https://coderouter.dev/api/vm/reflection", {
      headers: { authorization: "Bearer cmux-vm-edge-placeholder" },
    });
    expect(await requireVmPrincipal(noToken, { authenticate: boundIdentity, loadVm: async () => self })).toEqual({ ok: false, reason: "missing_route_token" });
    expect(await requireVmPrincipal(guestRequest({ [VM_ID_HEADER]: PEER_ID }), { authenticate: boundIdentity, loadVm: async () => self })).toEqual({ ok: false, reason: "vm_mismatch" });
    expect(await requireVmPrincipal(guestRequest({ [ROUTE_TOKEN_HEADER]: "crt_revoked" }), { authenticate: boundIdentity, loadVm: async () => self })).toEqual({ ok: false, reason: "invalid_route_token" });
    const unbound = async () => ({ teamId: "team-1", stackUserId: "user-1", vmId: null });
    expect(await requireVmPrincipal(guestRequest(), { authenticate: unbound, loadVm: async () => self })).toEqual({ ok: false, reason: "vm_bound_token_required" });
  });

  test("rejects a missing, destroyed, or foreign machine even with a valid token", async () => {
    expect(await requireVmPrincipal(guestRequest(), { authenticate: boundIdentity, loadVm: async () => null })).toEqual({ ok: false, reason: "vm_not_found" });
    expect(await requireVmPrincipal(guestRequest(), { authenticate: boundIdentity, loadVm: async () => ({ ...self, status: "destroyed" }) })).toEqual({ ok: false, reason: "vm_not_live" });
    expect(await requireVmPrincipal(guestRequest(), { authenticate: boundIdentity, loadVm: async () => otherOwner })).toEqual({ ok: false, reason: "vm_owner_mismatch" });
  });

  test("ownership is the creating user or the billing team", () => {
    expect(vmPrincipalOwns(self, { stackUserId: "user-1", teamId: "team-x" })).toBe(true);
    expect(vmPrincipalOwns(self, { stackUserId: "user-x", teamId: "team-1" })).toBe(true);
    expect(vmPrincipalOwns(row({ id: SELF_ID, billingTeamId: null }), { stackUserId: "user-x", teamId: "user-1" })).toBe(false);
    expect(vmPrincipalOwns(self, { stackUserId: "user-x", teamId: "team-x" })).toBe(false);
  });

  test("failures map to the status a caller can act on, and never leak a token", async () => {
    expect(vmPrincipalFailureStatus("missing_route_token")).toBe(401);
    expect(vmPrincipalFailureStatus("vm_bound_token_required")).toBe(403);
    expect(vmPrincipalFailureStatus("vm_owner_mismatch")).toBe(403);
    expect(vmPrincipalFailureStatus("vm_not_found")).toBe(404);
    expect(vmPrincipalFailureStatus("vm_not_live")).toBe(409);
    const response = vmPrincipalFailureResponse("missing_route_token");
    expect(response.status).toBe(401);
    expect(response.headers.get("cache-control")).toBe("no-store");
    const body = await response.json() as Record<string, unknown>;
    expect(body.error).toBe("missing_route_token");
    expect(typeof body.message).toBe("string");
    expect(typeof body.action).toBe("string");
    expect(JSON.stringify(body)).not.toContain("crt_");
  });
});

describe("reflection payloads", () => {
  test("the index always names the machine and lists every path", () => {
    const index = reflectionIndex(context);
    expect(index.name).toBe("brave-otter");
    expect(index.display_name).toBe("build box");
    expect(index.vm_id).toBe(SELF_ID);
    expect(index.provider_vm_id).toBe(self.providerVmId);
    expect(index.owner).toEqual({ user_id: "user-1", email: "austin@example.com", display_name: "Austin" });
    expect(index.team_id).toBe("team-1");
    expect(index.plan_id).toBe("pro");
    expect(index.urls).toEqual({
      reflection: ["https://coderouter.cmux.internal/api/vm/reflection", "https://reflection.cmux.internal/"],
    });
    expect(index.paths).toEqual(REFLECTION_PATHS);
    expect((index.paths as { path: string }[]).map((entry) => entry.path)).toEqual(["/owner", "/machine", "/peers", "/integrations"]);
  });

  test("the index also serves the /api/vm/self view: schema, this machine, team, and every owner machine with routes", () => {
    // Distinct creation times so the newest-first order is unambiguous.
    const newest = row({ id: PEER_ID, slug: "vivid-newt", createdAt: new Date("2026-09-07T00:00:00Z"), providerMetadata: { networkIpv6: "fd00:7::9" } });
    const oldest = row({ id: ADDRESSLESS_ID, slug: "quiet-fox", status: "paused", createdAt: new Date("2026-09-01T00:00:00Z") });
    const selfRow = { ...self, createdAt: new Date("2026-09-05T00:00:00Z") };
    const index = reflectionIndex({ ...context, self: selfRow, siblings: [newest, selfRow, oldest, destroyed, otherOwner] }) as {
      schema: number;
      team: { id: string };
      machine: Record<string, unknown>;
      machines: Array<Record<string, unknown>>;
    };
    expect(index.schema).toBe(1);
    expect(index.team).toEqual({ id: "team-1" });
    // The caller, in the VmSelfMachine shape (`name` = label, `id` = provider id), never routed to itself.
    expect(index.machine).toEqual({
      id: selfRow.providerVmId,
      vmId: SELF_ID,
      name: "build box",
      displayName: "build box",
      slug: "brave-otter",
      status: "running",
      createdAt: "2026-09-05T00:00:00.000Z",
      self: true,
      network: { ipv4: "10.7.0.5", ipv6: "fd00:7::5" },
      route: null,
      reachable: false,
    });
    // Newest first, self included and flagged, destroyed and foreign rows gone,
    // a paused machine without an address listed but unreachable.
    expect(index.machines.map((machine) => [machine.vmId, machine.self, machine.reachable])).toEqual([
      [PEER_ID, false, true],
      [SELF_ID, true, false],
      [ADDRESSLESS_ID, false, false],
    ]);
    expect(index.machines[0]).toMatchObject({ id: newest.providerVmId, name: "vivid-newt", route: "ws://[fd00:7::9]:1337/v1/link" });
    expect(index.machines[2]).toMatchObject({ status: "paused", route: null });
  });

  test("a caller still provisioning (no provider id) is its own machine entry by row id", () => {
    const provisioning = row({ id: SELF_ID, providerVmId: null, slug: "new-hare", status: "provisioning" });
    const index = reflectionIndex({ ...context, self: provisioning, siblings: [provisioning] }) as {
      machine: Record<string, unknown>;
      machines: Array<Record<string, unknown>>;
    };
    expect(index.machine).toMatchObject({ id: SELF_ID, vmId: SELF_ID, name: "new-hare", self: true, route: null });
    // The list keeps the /api/vm/self filter: no provider id, no entry.
    expect(index.machines).toEqual([]);
  });

  test("a machine without a slug or label falls back to its provider id", () => {
    const bare = { ...context, self: row({ id: SELF_ID, providerVmId: "fs-abc" }) };
    const index = reflectionIndex(bare);
    expect(index.name).toBe("fs-abc");
    expect(index.display_name).toBe("fs-abc");
  });

  test("/owner and /machine expose the snapshot, size, network, and desktop facts", () => {
    expect(reflectionOwner(context)).toEqual({
      user_id: "user-1", email: "austin@example.com", display_name: "Austin", team_id: "team-1", plan_id: "pro",
    });
    const machine = reflectionMachine(context);
    expect(machine).toMatchObject({
      vm_id: SELF_ID,
      name: "brave-otter",
      status: "running",
      provider: "freestyle",
      image_id: "sh-devbox-desktop",
      image_version: "2026-09-02-r4",
      created_at: "2026-09-06T00:00:00.000Z",
      size: { memory_mb: 20480, cpu: 5, disk_mb: 32768 },
      network: { ipv4: "10.7.0.5", ipv6: "fd00:7::5" },
      has_desktop: true,
    });
    expect(reflectionSize({})).toEqual({ memory_mb: null, cpu: null, disk_mb: null });
    expect(reflectionSize({ cmuxResourceReservation: { memoryMb: -1, vcpus: "2" } })).toEqual({ memory_mb: null, cpu: null, disk_mb: null });
  });

  test("/peers lists the owner's other live machines with daemon routes, excluding self, destroyed, and foreign rows", () => {
    const { peers } = reflectionPeers(context);
    expect(peers.map((entry) => entry.name)).toEqual(["quiet-fox", "vivid-newt"]);
    const newt = peers[1]!;
    expect(newt).toEqual({
      name: "vivid-newt",
      display_name: "vivid-newt",
      vm_id: PEER_ID,
      provider_vm_id: peer.providerVmId,
      status: "running",
      network: { ipv4: null, ipv6: "fd00:7::9" },
      route: "ws://[fd00:7::9]:1337/v1/link",
      reachable: true,
      help: "cmux vm exec vivid-newt -- <command>",
    });
    expect(peers[0]).toMatchObject({ name: "quiet-fox", status: "paused", route: null, reachable: false });
  });

  test("peer routes prefer IPv6 and fall back to IPv4", () => {
    expect(reflectionPeerRoute({ ipv4: "10.7.0.5", ipv6: "fd00:7::5" })).toBe("ws://[fd00:7::5]:1337/v1/link");
    expect(reflectionPeerRoute({ ipv4: "10.7.0.5", ipv6: null })).toBe("ws://10.7.0.5:1337/v1/link");
    expect(reflectionPeerRoute({ ipv4: null, ipv6: null })).toBeNull();
  });

  test("personal machines (no billing team) see only the same user's team-less machines", () => {
    const personal = row({ id: SELF_ID, slug: "solo", billingTeamId: null, userId: "user-solo" });
    const sibling = row({ id: PEER_ID, slug: "solo-two", billingTeamId: null, userId: "user-solo", providerMetadata: { networkIpv4: "10.1.0.2" } });
    const teamRow = row({ id: OTHER_OWNER_ID, slug: "teamed", billingTeamId: "team-z", userId: "user-solo" });
    const { peers } = reflectionPeers({ ...context, self: personal, siblings: [personal, sibling, teamRow] });
    expect(peers.map((entry) => entry.name)).toEqual(["solo-two"]);
  });

  test("/integrations carries a help command per capability and a desktop only when there is a screen", () => {
    const withScreen = reflectionIntegrations(context).integrations;
    expect(withScreen.every((entry) => entry.type && entry.name && entry.help.startsWith("cmux ") || entry.type === "desktop")).toBe(true);
    expect(withScreen.map((entry) => entry.type)).toEqual([
      "reflection", "llm", "agent", "agent", "agent", "agent", "notify", "peers", "env", "layout", "desktop",
    ]);
    expect(withScreen.find((entry) => entry.type === "llm")?.help).toBe("cmux coderouter models");
    expect(withScreen.filter((entry) => entry.type === "agent").map((entry) => entry.name)).toEqual(["claude", "codex", "opencode", "pi"]);
    const headless = reflectionIntegrations({ ...context, hasDesktop: false }).integrations;
    expect(headless.some((entry) => entry.type === "desktop")).toBe(false);
    const unknown = reflectionIntegrations({ ...context, hasDesktop: null }).integrations;
    expect(unknown.some((entry) => entry.type === "desktop")).toBe(false);
  });

  test("the dispatcher normalizes paths and answers 404 with the index of paths", () => {
    expect(normalizeReflectionPath("")).toBe("/");
    expect(normalizeReflectionPath("/")).toBe("/");
    expect(normalizeReflectionPath("peers")).toBe("/peers");
    expect(normalizeReflectionPath("/Peers/")).toBe("/peers");
    expect(reflectionPayload("/", context).status).toBe(200);
    expect(reflectionPayload("/peers", context).body).toEqual(reflectionPeers(context));
    expect(reflectionPayload("integrations/", context).body).toEqual(reflectionIntegrations(context));
    const missing = reflectionPayload("/tags", context);
    expect(missing.status).toBe(404);
    expect(missing.body).toEqual({ error: "not_found", path: "/tags", paths: REFLECTION_PATHS });
  });
});
