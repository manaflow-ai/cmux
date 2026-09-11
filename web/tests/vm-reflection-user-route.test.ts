import { afterAll, beforeAll, beforeEach, describe, expect, mock, test } from "bun:test";
import type { AuthedUser } from "../services/vms/auth";
import { vmEdgeAliasDomain, vmReflectionAliasDomain } from "../services/coderouter/vmGuestEnv";
import {
  REFLECTION_PATHS,
  reflectionHasDesktop,
  reflectionIndex,
  reflectionMachine,
  reflectionPeers,
  type ReflectionContext,
  type ReflectionOwner,
} from "../services/vms/reflection";
import type { VmPrincipalRow } from "../services/vms/vmPrincipalContract";

// GET /api/vm/[id]/reflection/[[...path]]: `cmux vm self <machine> [path]` from
// the Mac. The user's session names a machine the user owns, and the answer is
// built by the SAME payload builders and owner-machine loader the guest route
// uses, so a machine and its owner's Mac never disagree about the machine.
// bun's mock.module is process-global, so every override delegates to the
// real implementation unless this suite is running (`active`), the pattern
// vm-pause-resume-route.test.ts uses.

let active = false;
let authedUser: AuthedUser | null = null;
const programs: Array<Record<string, unknown>> = [];
const storeCalls: string[] = [];
let routeResult: { ok: true; value: VmPrincipalRow } | { ok: false; response: Response };
let recordedOwner: ReflectionOwner;

const realAuth = await import("../services/vms/auth");
const realVerifyRequest = realAuth.verifyRequest;
const realWorkflows = await import("../services/vms/workflows");
const realReflectVm = realWorkflows.reflectVm;
const realRouteWorkflow = await import("../services/vms/routeWorkflow");
const realRunVmRoute = realRouteWorkflow.runVmRoute;
const realStore = await import("../services/vms/reflectionStore");
const realListOwnerLiveVms = realStore.listOwnerLiveVms;
const realLoadReflectionOwner = realStore.loadReflectionOwner;

const SELF_ID = "11111111-2222-4333-8444-555555555555";
const PEER_ID = "22222222-2222-4333-8444-555555555555";
const OTHER_OWNER_ID = "33333333-2222-4333-8444-555555555555";

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
  providerVmId: "fs-1",
  slug: "brave-otter",
  displayName: "build box",
  providerMetadata: { networkIpv4: "10.7.0.5", networkIpv6: "fd00:7::5" },
});
const peer = row({ id: PEER_ID, slug: "vivid-newt", createdAt: new Date("2026-09-07T00:00:00Z"), providerMetadata: { networkIpv6: "fd00:7::9" } });
const otherOwner = row({ id: OTHER_OWNER_ID, slug: "someone-elses", userId: "user-9", billingTeamId: "team-9" });
const siblings = [self, peer, otherOwner];

mock.module("../services/vms/auth", () => ({
  ...realAuth,
  verifyRequest: ((request: Request, options?: unknown) =>
    active ? Promise.resolve(authedUser) : realVerifyRequest(request, options as never)) as typeof realVerifyRequest,
}));

mock.module("../services/vms/workflows", () => ({
  ...realWorkflows,
  reflectVm: ((input: Parameters<typeof realReflectVm>[0]) => {
    if (!active) return realReflectVm(input);
    programs.push(input as Record<string, unknown>);
    return { sentinel: "reflect" } as unknown as ReturnType<typeof realReflectVm>;
  }) as typeof realReflectVm,
}));

mock.module("../services/vms/routeWorkflow", () => ({
  ...realRouteWorkflow,
  runVmRoute: (async (program: unknown, options?: unknown) => {
    if (!active) return realRunVmRoute(program as never, options as never);
    expect((program as { sentinel?: string }).sentinel).toBe("reflect");
    return routeResult;
  }) as typeof realRunVmRoute,
}));

mock.module("../services/vms/reflectionStore", () => ({
  ...realStore,
  listOwnerLiveVms: (async (vm: VmPrincipalRow) => {
    if (!active) return realListOwnerLiveVms(vm);
    storeCalls.push(`siblings:${vm.id}`);
    return siblings;
  }) as typeof realListOwnerLiveVms,
  loadReflectionOwner: (async (principal: Parameters<typeof realLoadReflectionOwner>[0]) => {
    if (!active) return realLoadReflectionOwner(principal);
    storeCalls.push(`owner:${principal.userId}:${principal.teamId}`);
    return recordedOwner;
  }) as typeof realLoadReflectionOwner,
}));

const { GET } = await import("../app/api/vm/[id]/reflection/[[...path]]/route");

const owner: AuthedUser = {
  id: "user-1",
  isAnonymous: false,
  displayName: "Austin",
  primaryEmail: "austin@example.com",
  billingCustomerType: "team",
  billingTeamId: "team-1",
  selectedTeamId: "team-1",
  teams: [{ id: "team-1", displayName: "cmux", billingPlanId: "pro", billingSeats: 3 }],
  teamIds: ["team-1"],
  userBillingPlanId: null,
  billingPlanId: "pro",
  billingSeats: 3,
};
const teammate: AuthedUser = { ...owner, id: "user-2", displayName: "Sam", primaryEmail: "sam@example.com" };

function get(path: string): Request {
  return new Request(`https://cmux.test${path}`, {
    headers: { authorization: "Bearer access-token", "x-stack-refresh-token": "refresh-token" },
  });
}

function params(segments?: string[]) {
  return { params: Promise.resolve({ id: "fs-1", ...(segments ? { path: segments } : {}) }) };
}

/** What the route must have built: the guest context, with the owner as the route completes it. */
function expectedContext(ownerOverrides: Partial<ReflectionOwner> = {}): ReflectionContext {
  return {
    self,
    owner: { ...recordedOwner, ...ownerOverrides },
    siblings,
    aliasOrigin: `https://${vmEdgeAliasDomain()}`,
    reflectionOrigin: `https://${vmReflectionAliasDomain()}`,
    hasDesktop: reflectionHasDesktop(self),
  };
}

describe("GET /api/vm/[id]/reflection", () => {
  beforeAll(() => {
    active = true;
  });
  afterAll(() => {
    active = false;
  });
  beforeEach(() => {
    authedUser = owner;
    programs.length = 0;
    storeCalls.length = 0;
    routeResult = { ok: true, value: self };
    // What the identity snapshot recorded: no email yet (a machine older than snapshots).
    recordedOwner = { userId: "user-1", email: null, displayName: null, teamId: "team-1", planId: "pro" };
  });

  test("an unauthenticated request never reaches the workflow or the loaders", async () => {
    authedUser = null;
    const response = await GET(get("/api/vm/fs-1/reflection"), params());
    expect(response.status).toBe(401);
    expect(programs).toEqual([]);
    expect(storeCalls).toEqual([]);
  });

  test("the index is the guest index for the owned machine, with the owner completed from the caller's session", async () => {
    const response = await GET(get("/api/vm/fs-1/reflection"), params());
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(response.headers.get("content-type")).toBe("application/json");
    // Ownership check ran with the caller's scope, by the machine's provider id.
    expect(programs).toEqual([{ userId: "user-1", billingTeamId: "team-1", teamIds: ["team-1"], providerVmId: "fs-1" }]);
    // Same loaders as the guest route: the machine's owner list and the owner snapshot for its team.
    expect(storeCalls.sort()).toEqual([`owner:user-1:team-1`, `siblings:${SELF_ID}`]);
    const body = await response.json();
    const expected = JSON.parse(JSON.stringify(reflectionIndex(expectedContext({ email: "austin@example.com", displayName: "Austin" }))));
    expect(body).toEqual(expected);
    expect(body.name).toBe("brave-otter");
    expect(body.owner).toEqual({ user_id: "user-1", email: "austin@example.com", display_name: "Austin" });
    expect(body.paths).toEqual(REFLECTION_PATHS);
    // Peers and self as the guest sees them: newest first, self flagged, the foreign row gone.
    expect(body.machines.map((machine: { vmId: string; self: boolean; reachable: boolean }) => [machine.vmId, machine.self, machine.reachable])).toEqual([
      [PEER_ID, false, true],
      [SELF_ID, true, false],
    ]);
  });

  test("a teammate reading another member's machine sees the recorded owner, never their own identity", async () => {
    authedUser = teammate;
    const response = await GET(get("/api/vm/fs-1/reflection/owner"), params(["owner"]));
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ user_id: "user-1", email: null, display_name: null, team_id: "team-1", plan_id: "pro" });
    expect(programs[0]).toMatchObject({ userId: "user-2" });
  });

  test("sub-paths answer exactly what the guest builders produce", async () => {
    const peers = await GET(get("/api/vm/fs-1/reflection/peers"), params(["peers"]));
    expect(peers.status).toBe(200);
    expect(await peers.json()).toEqual(JSON.parse(JSON.stringify(reflectionPeers(expectedContext()))));

    const machine = await GET(get("/api/vm/fs-1/reflection/machine/"), params(["machine", ""]));
    expect(machine.status).toBe(200);
    const machineBody = await machine.json();
    expect(machineBody).toEqual(JSON.parse(JSON.stringify(reflectionMachine(expectedContext()))));
    expect(machineBody.has_desktop).toBe(reflectionHasDesktop(self));
    expect(machineBody.network).toEqual({ ipv4: "10.7.0.5", ipv6: "fd00:7::5" });
  });

  test("an unknown path is 404 with the index of paths", async () => {
    const response = await GET(get("/api/vm/fs-1/reflection/tags"), params(["tags"]));
    expect(response.status).toBe(404);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(await response.json()).toEqual({ error: "not_found", path: "/tags", paths: REFLECTION_PATHS });
  });

  test("a machine the caller does not own is the workflow's not-found answer, and nothing is loaded", async () => {
    routeResult = {
      ok: false,
      response: new Response(JSON.stringify({ error: "vm_not_found" }), { status: 404, headers: { "content-type": "application/json" } }),
    };
    const response = await GET(get("/api/vm/fs-1/reflection"), params());
    expect(response.status).toBe(404);
    expect((await response.json()).error).toBe("vm_not_found");
    expect(storeCalls).toEqual([]);
  });

  test("a personal machine (no billing team) reports the caller's resolved billing scope as its team", async () => {
    const personal = { ...self, billingTeamId: null };
    routeResult = { ok: true, value: personal };
    recordedOwner = { ...recordedOwner, teamId: "team-1" };
    const response = await GET(get("/api/vm/fs-1/reflection"), params([]));
    expect(response.status).toBe(200);
    // The owner snapshot was loaded for the team the caller's session resolved to.
    expect(storeCalls).toContain("owner:user-1:team-1");
  });
});
