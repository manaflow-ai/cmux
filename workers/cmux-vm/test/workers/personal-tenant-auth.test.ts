/**
 * A Stack team marked as a cmux VM personal tenant belongs to one user. Stack membership
 * alone (an invitee through cmux.com) must never reach that user's VMs.
 */
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { bearer, VM_ENDPOINTS, type VmEndpointCase } from "../support/endpoints.ts";
import { makeHarness } from "../support/harness.ts";

type Harness = Awaited<ReturnType<typeof makeHarness>>;

const TENANT = "team_alpha";
const marker = (owner: unknown) => ({ cmuxVmPersonalTenant: { v: 1, stack_user: owner, nonce: "nonce-1" } });

let h: Harness;
beforeEach(async () => {
  h = await makeHarness();
});
afterEach(async () => {
  await h.dispose();
});

const call = (endpoint: VmEndpointCase, vmId: string, headers: Record<string, string>) =>
  endpoint.bytes === undefined
    ? h.request(endpoint.path(vmId), headers, { method: endpoint.method, body: endpoint.json })
    : h.send(endpoint.path(vmId), headers, endpoint.method, endpoint.bytes);
const as = async (user: string) => ({ ...bearer(await h.sessionToken(user)), "x-cmux-team-id": TENANT });

describe("a cmux VM personal tenant", () => {
  it("serves its owner's Stack session", async () => {
    h.setStackMetadata(TENANT, marker("user_owner"));
    h.addMember(TENANT, "user_owner");
    h.addVm(TENANT);
    expect((await h.request("/v1/vms", await as("user_owner"))).status).toBe(200);
  });

  it("refuses another member's Stack session on every VM operation without calling upstream", async () => {
    h.setStackMetadata(TENANT, marker("user_owner"));
    h.addMember(TENANT, "user_owner");
    h.addMember(TENANT, "user_invitee");
    const { vmId } = h.addVm(TENANT);
    const headers = await as("user_invitee");
    expect([403, 404]).toContain((await h.request("/v1/vms", headers)).status);
    for (const endpoint of VM_ENDPOINTS) expect([403, 404]).toContain((await call(endpoint, vmId, headers)).status);
    expect(h.upstreamRequests).toHaveLength(0);
  });

  it("fails closed when the marker cannot be read", async () => {
    h.setStackMetadata(TENANT, { cmuxVmPersonalTenant: "garbled" });
    h.addMember(TENANT, "user_owner");
    expect((await h.request("/v1/vms", await as("user_owner"))).status).not.toBe(200);
  });
});
