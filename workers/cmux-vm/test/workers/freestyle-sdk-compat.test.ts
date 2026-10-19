import { describe, expect, it } from "vitest";
import { Freestyle, FreestyleApiError } from "freestyle";
import { makeHarness } from "../support/harness.ts";

const allScopes = ["vm:read", "vm:write", "vm:exec", "vm:files", "vm:terminal", "snapshot:*", "snapshot:read", "snapshot:write"] as const;

describe("Freestyle SDK compatibility", () => {
  it("keeps the SDK lifecycle and identity surfaces wire-compatible", async () => {
    const h = await makeHarness();
    try {
      const key = await h.addKey("team_alpha", allScopes);
      const client = new Freestyle({ baseUrl: "https://vm.test", apiKey: key, fetch: h.handler });
      const created = await client.vms.create({ firewall: { rules: [] } });
      expect(created.vmId).toMatch(/^vm-/u);
      expect((await client.vms.get(created.vmId)).id).toBe(created.vmId);
      expect((await client.vms.list()).totalCount).toBe(1);
      expect((await client.vms.ref(created.vmId).exec("echo hi")).statusCode).toBe(0);
      await client.vms.ref(created.vmId).pause();
      await client.vms.ref(created.vmId).start();
      const snapshot = await client.vms.ref(created.vmId).snapshot();
      expect(snapshot.snapshotId).toMatch(/^sh-/u);
      expect((await client.vms.snapshots.list()).totalCount).toBe(1);
      const identity = await client.identities.create();
      const permission = await identity.identity.permissions.vm.grant({ vmId: created.vmId });
      expect(permission.vmId).toBe(created.vmId);
      const token = await identity.identity.tokens.create();
      const identityClient = new Freestyle({ baseUrl: "https://vm.test", identityAccessToken: token.token, fetch: h.handler });
      expect((await identityClient.vms.ref(created.vmId).exec("echo identity")).statusCode).toBe(0);
      await identity.identity.tokens.list();
      await identity.identity.tokens.revoke(token.id);
      await identity.identity.delete();
      await client.vms.snapshots.delete(snapshot.snapshotId);
      await client.vms.delete(created.vmId);
    } finally {
      await h.dispose();
    }
  });

  it("hides tenant A resources from tenant B", async () => {
    const h = await makeHarness();
    try {
      const keyA = await h.addKey("team_alpha", allScopes);
      const keyB = await h.addKey("team_bravo", allScopes);
      const a = new Freestyle({ baseUrl: "https://vm.test", apiKey: keyA, fetch: h.handler });
      const b = new Freestyle({ baseUrl: "https://vm.test", apiKey: keyB, fetch: h.handler });
      const created = await a.vms.create({ firewall: { rules: [] } });
      await expect(b.vms.get(created.vmId)).rejects.toMatchObject({ status: 404, code: "NOT_FOUND" });
      expect((await b.vms.list()).totalCount).toBe(0);
      await expect(b.vms.ref(created.vmId).exec("id")).rejects.toBeInstanceOf(FreestyleApiError);
    } finally {
      await h.dispose();
    }
  });
});
