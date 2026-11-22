/**
 * GET /v1/vms/{vmId} end to end: real API, middleware, proofs, session
 * verification and upstream client, with in-memory stores and a fake upstream.
 * Runs inside workerd via @cloudflare/vitest-pool-workers.
 */
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { generateKeyPair } from "jose";
import { makeHarness } from "../support/harness.ts";

type Harness = Awaited<ReturnType<typeof makeHarness>>;

const TENANT_A = "team_alpha";
const TENANT_B = "team_bravo";
const bearer = (token: string) => ({ authorization: `Bearer ${token}` });

let h: Harness;
beforeEach(async () => {
  h = await makeHarness();
});
afterEach(async () => {
  await h.dispose();
});

describe("tenant isolation", () => {
  it("returns 404, not 403, when tenant B asks for tenant A's VM", async () => {
    const { vmId } = h.addVm(TENANT_A);
    const keyB = await h.addKey(TENANT_B, ["vm:read"]);

    const response = await h.request(`/v1/vms/${vmId}`, bearer(keyB));

    expect(response.status).toBe(404);
    expect(await response.json()).toEqual({ _tag: "NotFound", message: "VM not found" });
    expect(h.upstreamRequests).toHaveLength(0);
  });

  it("gives the same 404 for a VM that does not exist and for a malformed id", async () => {
    const keyB = await h.addKey(TENANT_B, ["vm:read"]);
    const missing = await h.request("/v1/vms/vm_00000000000000000000000000", bearer(keyB));
    const malformed = await h.request("/v1/vms/not-a-vm-id", bearer(keyB));
    expect(missing.status).toBe(404);
    expect(malformed.status).toBe(404);
    expect(await missing.json()).toEqual(await malformed.json());
  });

  it("returns 404 for a session in tenant B asking for tenant A's VM", async () => {
    const { vmId } = h.addVm(TENANT_A);
    h.addMember(TENANT_B, "user_bob");
    const token = await h.sessionToken("user_bob");

    const response = await h.request(`/v1/vms/${vmId}`, { ...bearer(token), "x-cmux-team-id": TENANT_B });

    expect(response.status).toBe(404);
    expect(h.upstreamRequests).toHaveLength(0);
  });

  it("returns 404 when the VM is outside the key's resource allowlist", async () => {
    const { vmId } = h.addVm(TENANT_A);
    const other = h.addVm(TENANT_A);
    const key = await h.addKey(TENANT_A, ["vm:read"], { allowlist: [other.vmId] });
    const response = await h.request(`/v1/vms/${vmId}`, bearer(key));
    expect(response.status).toBe(404);
  });
});

describe("team header", () => {
  it("is ignored for API keys: the key's own tenant always applies", async () => {
    const own = h.addVm(TENANT_A);
    const other = h.addVm(TENANT_B);
    const keyA = await h.addKey(TENANT_A, ["vm:read"]);
    const asB = { ...bearer(keyA), "x-cmux-team-id": TENANT_B };

    expect((await h.request(`/v1/vms/${own.vmId}`, asB)).status).toBe(200);
    expect((await h.request(`/v1/vms/${other.vmId}`, asB)).status).toBe(404);
    expect(h.upstreamRequests.map((call) => call.path)).toEqual([`/v5/vms/${own.upstreamId}`]);
  });

  it("must name a team the session user belongs to", async () => {
    const theirs = h.addVm(TENANT_B);
    h.addMember(TENANT_A, "user_alice");
    const token = await h.sessionToken("user_alice");

    const response = await h.request(`/v1/vms/${theirs.vmId}`, { ...bearer(token), "x-cmux-team-id": TENANT_B });

    expect(response.status).toBe(403);
    expect(await response.json()).toEqual({ _tag: "Forbidden", message: "You are not a member of this team" });
    expect(h.upstreamRequests).toHaveLength(0);
  });
});

describe("scopes", () => {
  it("refuses a key without vm:read with 403 and does not reach upstream", async () => {
    const { vmId } = h.addVm(TENANT_A);
    const key = await h.addKey(TENANT_A, ["vm:write", "vm:exec", "admin"]);

    const response = await h.request(`/v1/vms/${vmId}`, bearer(key));

    expect(response.status).toBe(403);
    expect(await response.json()).toEqual({
      _tag: "Forbidden",
      message: "This credential lacks the vm:read scope",
      missingScope: "vm:read",
    });
    expect(h.upstreamRequests).toHaveLength(0);
  });
});

describe("owner reads", () => {
  it("returns the VM by its cmux id and leaks no upstream id", async () => {
    const { vmId, upstreamId } = h.addVm(TENANT_A, "paused");
    const key = await h.addKey(TENANT_A, ["vm:read"]);

    const response = await h.request(`/v1/vms/${vmId}`, bearer(key));

    expect(response.status).toBe(200);
    const text = await response.text();
    expect(JSON.parse(text)).toEqual({
      id: vmId,
      displayName: null,
      labels: {},
      state: "paused",
      resources: { vcpus: 4, memoryMib: 8192, diskMib: 16384 },
      idleTimeoutSeconds: 300,
      maxRunSeconds: null,
      autoDeleteSeconds: null,
      createdAt: "2026-10-01T00:00:00Z",
      updatedAt: "2026-10-02T00:00:00Z",
    });
    expect(text).not.toContain(upstreamId);
    expect(text).not.toContain("tenant-slug");
    expect(text).not.toContain("leak-check");
    expect(text.toLowerCase()).not.toContain("freestyle");
    expect(h.upstreamRequests.map((call) => call.path)).toEqual([`/v5/vms/${upstreamId}`]);
  });

  it("accepts a session token for a member of the named team", async () => {
    const { vmId } = h.addVm(TENANT_A);
    h.addMember(TENANT_A, "user_alice");
    const token = await h.sessionToken("user_alice");
    const response = await h.request(`/v1/vms/${vmId}`, { ...bearer(token), "x-cmux-team-id": TENANT_A });
    expect(response.status).toBe(200);
  });

  it("maps a VM that vanished upstream to 404", async () => {
    const { vmId, upstreamId } = h.addVm(TENANT_A);
    h.dropUpstreamVm(upstreamId);
    const key = await h.addKey(TENANT_A, ["vm:read"]);
    const response = await h.request(`/v1/vms/${vmId}`, bearer(key));
    expect(response.status).toBe(404);
  });
});

describe("authentication", () => {
  it("rejects a missing, unknown, revoked or expired key with 401", async () => {
    const { vmId } = h.addVm(TENANT_A);
    const revoked = await h.addKey(TENANT_A, ["vm:read"], { revoked: true });
    const expired = await h.addKey(TENANT_A, ["vm:read"], { expiresAt: new Date(Date.now() - 1000) });
    const unknown = `cmuxvm_sk_${"A".repeat(43)}`;
    for (const headers of [{}, bearer(revoked), bearer(expired), bearer(unknown), bearer("cmuxvm_sk_short")]) {
      const response = await h.request(`/v1/vms/${vmId}`, headers);
      expect(response.status).toBe(401);
    }
    expect(h.upstreamRequests).toHaveLength(0);
  });

  it("rejects a session without a team header, a non-member, a forged and an expired token", async () => {
    const { vmId } = h.addVm(TENANT_A);
    h.addMember(TENANT_A, "user_alice");
    const good = await h.sessionToken("user_alice");
    const forged = await h.sessionToken("user_alice", { key: (await generateKeyPair("ES256")).privateKey });
    const expired = await h.sessionToken("user_alice", { expiresIn: "-10m" });
    const outsider = await h.sessionToken("user_mallory");

    expect((await h.request(`/v1/vms/${vmId}`, bearer(good))).status).toBe(401);
    expect((await h.request(`/v1/vms/${vmId}`, { ...bearer(forged), "x-cmux-team-id": TENANT_A })).status).toBe(401);
    expect((await h.request(`/v1/vms/${vmId}`, { ...bearer(expired), "x-cmux-team-id": TENANT_A })).status).toBe(401);
    expect((await h.request(`/v1/vms/${vmId}`, { ...bearer(outsider), "x-cmux-team-id": TENANT_A })).status).toBe(403);
    expect(h.upstreamRequests).toHaveLength(0);
  });

  it("serves health without credentials", async () => {
    const response = await h.request("/healthz");
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true });
  });
});
