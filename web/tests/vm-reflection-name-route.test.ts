import { afterAll, beforeAll, describe, expect, mock, test } from "bun:test";
import { vmPromptIdentity } from "../services/vms/guestPrompt";
import type { VmPrincipalRow } from "../services/vms/vmPrincipalContract";

// GET /api/vm/reflection/name: the guest's cmux-prompt-sync fetches this every
// 30 s and writes the answer to /etc/cmux/vm-name. Create and rename write the
// same file through vmPromptIdentity, so the two must agree, or a named
// machine's prompt flips back to its generated slug within 30 s.
// bun's mock.module is process-global; the override delegates unless active.

let active = false;
let principal: VmPrincipalRow;

const realPrincipal = await import("../services/vms/vmPrincipal");
const realRequireVmPrincipal = realPrincipal.requireVmPrincipal;

mock.module("../services/vms/vmPrincipal", () => ({
  ...realPrincipal,
  requireVmPrincipal: ((request: Request, ...rest: unknown[]) =>
    active
      ? Promise.resolve({ ok: true, principal: { vm: principal, userId: "user-1", teamId: "team-1" } })
      : (realRequireVmPrincipal as (...args: unknown[]) => unknown)(request, ...rest)) as typeof realRequireVmPrincipal,
}));

const { GET } = await import("../app/api/vm/reflection/name/route");

function row(overrides: Partial<VmPrincipalRow>): VmPrincipalRow {
  return {
    id: "11111111-2222-4333-8444-555555555555",
    userId: "user-1",
    ownerTeamId: "team-1",
    coderouterPoolId: null,
    billingTeamId: "team-1",
    billingPlanId: null,
    provider: "freestyle",
    providerVmId: "provider-vm-1",
    displayName: null,
    slug: "hardy-pink-jay",
    imageId: null,
    imageVersion: null,
    status: "running",
    createdAt: new Date("2026-09-28T00:00:00Z"),
    providerMetadata: {},
    ...overrides,
  } as VmPrincipalRow;
}

async function nameFor(vm: VmPrincipalRow): Promise<string> {
  principal = vm;
  const response = await GET(new Request("https://reflection.cmux.internal/name"));
  expect(response.status).toBe(200);
  return ((await response.json()) as { name: string }).name;
}

describe("GET /api/vm/reflection/name", () => {
  beforeAll(() => { active = true; });
  afterAll(() => { active = false; });

  test("a named machine keeps the name create and rename wrote", async () => {
    const vm = row({ displayName: "Dogfood Box" });
    const written = vmPromptIdentity({ ...vm, updatedAt: vm.createdAt }).name;
    expect(written).toBe("dogfood-box");
    expect(await nameFor(vm)).toBe(written);
  });

  test("an unnamed machine still answers its slug", async () => {
    expect(await nameFor(row({ displayName: null }))).toBe("hardy-pink-jay");
  });
});
