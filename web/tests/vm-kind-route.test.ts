import { afterAll, beforeAll, describe, expect, mock, test } from "bun:test";
import type { VmPrincipalRow } from "../services/vms/vmPrincipalContract";

// Move to Cloud on a production personal machine (cx-rppd.14). cmux-tui on a
// Cloud VM refuses to start or receive a chat unless the root-owned
// /etc/cmux/vm-kind reads `owner` (cmux-tui agent_start_host.rs). The guest
// asks GET /api/vm/reflection/kind which kind it is; the answer comes from
// the machine's own billing row, never from the guest or transient membership.

// bun's mock.module is process-global; each override delegates unless active.
let active = false;
let principal: VmPrincipalRow;

const realPrincipal = await import("../services/vms/vmPrincipal");
const realRequireVmPrincipal = realPrincipal.requireVmPrincipal;
mock.module("../services/vms/vmPrincipal", () => ({
  ...realPrincipal,
  requireVmPrincipal: ((request: Request, ...rest: unknown[]) =>
    active
      ? Promise.resolve({ ok: true, principal: { vm: principal, userId: principal.userId, teamId: principal.ownerTeamId } })
      : (realRequireVmPrincipal as (...args: unknown[]) => unknown)(request, ...rest)) as typeof realRequireVmPrincipal,
}));
const { GET } = await import("../app/api/vm/reflection/kind/route");
const { resolveVmGuestKind, vmIsOnPersonalAccount } = await import("../services/vms/vmKind");

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
  test("a machine on the creator's own account is owner", () => {
    const vm = row({ userId: "user-1", ownerTeamId: "user-1" });
    expect(vmIsOnPersonalAccount(vm)).toBe(true);
    expect(resolveVmGuestKind(vm)).toBe("owner");
  });

  test("a team machine is always shared, including a solo team", () => {
    const vm = row({ userId: "user-1", ownerTeamId: "team-1" });
    expect(vmIsOnPersonalAccount(vm)).toBe(false);
    expect(resolveVmGuestKind(vm)).toBe("team");
  });

  test("a missing billing owner is unknown, never owner", () => {
    expect(resolveVmGuestKind(row({ ownerTeamId: " " }))).toBeNull();
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
    const personal = row({ ownerTeamId: "user-1" });
    expect(await kindFor(personal)).toEqual({ status: 200, body: { vm_id: personal.id, kind: "owner" } });
    const solo = row({ ownerTeamId: "team-solo" });
    expect(await kindFor(solo)).toEqual({ status: 200, body: { vm_id: solo.id, kind: "team" } });
    const shared = row({ ownerTeamId: "team-shared" });
    expect(await kindFor(shared)).toEqual({ status: 200, body: { vm_id: shared.id, kind: "team" } });
  });

  test("a missing billing owner is a retryable 503 with no kind", async () => {
    const result = await kindFor(row({ ownerTeamId: " " }));
    expect(result.status).toBe(503);
    expect(result.body).toEqual({ error: "vm_kind_unavailable", retryable: true });
  });
});
