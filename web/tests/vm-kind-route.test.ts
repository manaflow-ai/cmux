import { afterAll, beforeAll, describe, expect, mock, test } from "bun:test";
import type { VmPrincipalRow } from "../services/vms/vmPrincipalContract";
import type { VmTeamMemberLookup } from "../services/vms/teamDirectory";

// Move to Cloud on a production personal machine (cx-rppd.14). cmux-tui on a
// Cloud VM refuses to start or receive a chat unless the root-owned
// /etc/cmux/vm-kind reads `owner` (cmux-tui agent_start_host.rs). The guest
// asks GET /api/vm/reflection/kind which kind it is; the answer comes from
// the machine's own row and its owner team's members, never from the guest.

// bun's mock.module is process-global; each override delegates unless active.
let active = false;
let principal: VmPrincipalRow;
let members: (teamId: string) => Promise<readonly string[] | null>;
const memberCalls: string[] = [];

const realPrincipal = await import("../services/vms/vmPrincipal");
const realRequireVmPrincipal = realPrincipal.requireVmPrincipal;
mock.module("../services/vms/vmPrincipal", () => ({
  ...realPrincipal,
  requireVmPrincipal: ((request: Request, ...rest: unknown[]) =>
    active
      ? Promise.resolve({ ok: true, principal: { vm: principal, userId: principal.userId, teamId: principal.ownerTeamId } })
      : (realRequireVmPrincipal as (...args: unknown[]) => unknown)(request, ...rest)) as typeof realRequireVmPrincipal,
}));
const realDirectory = await import("../services/vms/teamDirectory");
const realVmTeamDirectory = realDirectory.vmTeamDirectory;
mock.module("../services/vms/teamDirectory", () => ({
  ...realDirectory,
  vmTeamDirectory: () => active
    ? {
      listMemberIds: async (teamId: string) => {
        memberCalls.push(teamId);
        return members(teamId);
      },
    }
    : realVmTeamDirectory(),
}));

const { GET } = await import("../app/api/vm/reflection/kind/route");
const { resolveVmGuestKind, vmGuestKindFromMembers, vmIsOnPersonalAccount } = await import("../services/vms/vmKind");

let rowSeq = 0;
function row(overrides: Partial<VmPrincipalRow>): VmPrincipalRow {
  rowSeq += 1;
  return {
    id: `11111111-2222-4333-8444-${String(rowSeq).padStart(12, "0")}`,
    userId: "user-1",
    ownerTeamId: "user-1",
    coderouterPoolId: null,
    billingTeamId: null,
    billingPlanId: null,
    provider: "freestyle",
    providerVmId: "provider-vm-1",
    displayName: null,
    slug: "hardy-pink-jay",
    imageId: "sh-1",
    imageVersion: null,
    status: "running",
    createdAt: new Date("2026-10-12T00:00:00Z"),
    providerMetadata: {},
    ...overrides,
  } as VmPrincipalRow;
}

describe("machine kind (services/vms/vmKind.ts)", () => {
  const lookup = (memberIds: readonly string[] | null): VmTeamMemberLookup => ({ memberIds });

  test("a machine on the creator's own account is owner, with no team to ask", async () => {
    const asked: string[] = [];
    const vm = row({ userId: "user-1", ownerTeamId: "user-1" });
    expect(vmIsOnPersonalAccount(vm)).toBe(true);
    expect(await resolveVmGuestKind(vm, { listMembers: async (id) => { asked.push(id); return lookup([]); } })).toBe("owner");
    expect(asked).toEqual([]);
  });

  test("a team machine is owner only while the creator is the team's only member", () => {
    const vm = row({ userId: "user-1", ownerTeamId: "team-1" });
    expect(vmIsOnPersonalAccount(vm)).toBe(false);
    expect(vmGuestKindFromMembers(vm, lookup(["user-1"]))).toBe("owner");
    expect(vmGuestKindFromMembers(vm, lookup(["user-1", "user-2"]))).toBe("team");
    // The creator left: someone else's team.
    expect(vmGuestKindFromMembers(vm, lookup(["user-2"]))).toBe("team");
    expect(vmGuestKindFromMembers(vm, lookup([]))).toBe("team");
    // The team is gone: nobody's personal machine.
    expect(vmGuestKindFromMembers(vm, lookup(null))).toBe("team");
  });

  test("a failed member lookup is unknown, never owner", async () => {
    const vm = row({ userId: "user-1", ownerTeamId: "team-1" });
    expect(vmGuestKindFromMembers(vm, { error: "timeout" })).toBeNull();
    expect(vmGuestKindFromMembers(vm, { error: "error" })).toBeNull();
    expect(await resolveVmGuestKind(row({ ownerTeamId: " " }), { listMembers: async () => lookup(["user-1"]) })).toBeNull();
  });
});

describe("GET /api/vm/reflection/kind", () => {
  beforeAll(() => { active = true; });
  afterAll(() => { active = false; });

  async function kindFor(vm: VmPrincipalRow): Promise<{ status: number; body: Record<string, unknown> }> {
    principal = vm;
    const response = await GET(new Request("https://reflection.cmux.internal/kind"));
    return { status: response.status, body: (await response.json()) as Record<string, unknown> };
  }

  test("answers owner for a personal machine and team for a shared one", async () => {
    members = async (teamId) => (teamId === "team-solo" ? ["user-1"] : ["user-1", "user-2"]);
    const personal = row({ ownerTeamId: "user-1" });
    expect(await kindFor(personal)).toEqual({ status: 200, body: { vm_id: personal.id, kind: "owner" } });
    const solo = row({ ownerTeamId: "team-solo" });
    expect(await kindFor(solo)).toEqual({ status: 200, body: { vm_id: solo.id, kind: "owner" } });
    const shared = row({ ownerTeamId: "team-shared" });
    expect(await kindFor(shared)).toEqual({ status: 200, body: { vm_id: shared.id, kind: "team" } });
  });

  test("reuses a team's member list briefly, and never caches a failure", async () => {
    memberCalls.length = 0;
    members = async () => ["user-1"];
    await kindFor(row({ ownerTeamId: "team-cached" }));
    await kindFor(row({ ownerTeamId: "team-cached" }));
    expect(memberCalls).toEqual(["team-cached"]);
    let fail = true;
    members = async () => {
      if (fail) throw new Error("stack down");
      return ["user-1"];
    };
    expect((await kindFor(row({ ownerTeamId: "team-flaky" }))).status).toBe(503);
    fail = false;
    expect((await kindFor(row({ ownerTeamId: "team-flaky" }))).body.kind).toBe("owner");
    expect(memberCalls).toEqual(["team-cached", "team-flaky", "team-flaky"]);
  });

  test("a failed member lookup is a retryable 503 with no kind", async () => {
    members = async () => { throw new Error("stack down"); };
    const result = await kindFor(row({ ownerTeamId: "team-unreachable" }));
    expect(result.status).toBe(503);
    expect(result.body).toEqual({ error: "vm_kind_unavailable", retryable: true });
  });
});
