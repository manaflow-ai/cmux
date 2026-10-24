import { describe, expect, test } from "bun:test";

import { vmCreateDisabledReason } from "../services/vms/config";
import { GcpProvider } from "../services/vms/drivers/gcp";
import { SecretBytes, type ProviderCredential } from "../services/vms/drivers/types";
import { gcpCredentialFromRequest, wipeProviderCredential } from "../services/vms/routeInput";

const now = 1_735_689_600_000;

function credential(overrides: Partial<ProviderCredential> = {}): ProviderCredential {
  return {
    provider: "gcp",
    accessToken: new SecretBytes(new TextEncoder().encode("gcp-test-token")),
    expiresAtUnix: Math.floor(now / 1000) + 300,
    ...overrides,
  };
}

function json(value: unknown, status = 200): Response {
  return new Response(JSON.stringify(value), {
    status,
    headers: { "content-type": "application/json" },
  });
}

describe("GCP Labs provider", () => {
  test("is disabled by default and requires the Labs flag", () => {
    expect(vmCreateDisabledReason("gcp", {})).toContain("Labs");
    expect(vmCreateDisabledReason("gcp", { CMUX_VM_GCP_LABS_ENABLED: "1" })).toBeNull();
    expect(vmCreateDisabledReason("gcp", { CMUX_VM_GCP_LABS_ENABLED: "1", CMUX_VM_GCP_ENABLED: "0" })).toContain("gcp");
  });

  test("keeps the local credential redacted and wipes it after request use", () => {
    const parsed = gcpCredentialFromRequest(new Request("https://cmux.test", {
      headers: {
        "x-cmux-gcp-access-token": "local-token",
        "x-cmux-gcp-access-token-expires-at": String(Math.floor(Date.now() / 1000) + 300),
        "x-cmux-gcp-ssh-public-key": "ssh-ed25519 AAAA test",
      },
    }));
    expect(parsed).toBeDefined();
    expect(parsed?.expiresAtUnix).toBeGreaterThan(Math.floor(Date.now() / 1000));
    expect(JSON.stringify(parsed)).not.toContain("local-token");
    expect(String(parsed?.accessToken)).toBe("[redacted]");
    wipeProviderCredential(parsed);
    expect(parsed?.accessToken.utf8()).toBe("");
  });

  test("creates, stops, connects, and deletes without persisting the token", async () => {
    const calls: Array<{ url: string; init: RequestInit }> = [];
    const fetch = async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
      calls.push({ url: String(input), init: init ?? {} });
      if (calls.length === 1) return json({ name: "insert-op", status: "DONE" });
      if (calls.length === 2 || calls.length === 3) return json({
        name: "cmux-abc",
        status: "RUNNING",
        networkInterfaces: [{ networkIP: "10.0.0.4", accessConfigs: [{ natIP: "203.0.113.4" }] }],
      });
      return json({ name: `${calls.length}-op`, status: "DONE" });
    };
    const provider = new GcpProvider({ fetch, now: () => now });
    const local = credential({
      sshPublicKey: "ssh-ed25519 AAAA test",
      sshPrivateKeyPem: new SecretBytes(new TextEncoder().encode("PRIVATE KEY")),
    });
    const created = await provider.create({
      image: "projects/manaflow-437420/global/images/cmux-linux",
      displayName: "GCP Lab",
      providerMetadata: { project: "manaflow-437420", zone: "us-west1-b" },
      providerCredential: local,
    });
    expect(created.provider).toBe("gcp");
    expect(created.providerVmId).toMatch(/^manaflow-437420\/us-west1-b\//);
    expect(created.providerMetadata).not.toHaveProperty("accessToken");
    expect(JSON.stringify(created)).not.toContain("gcp-test-token");
    expect(String(calls[0]?.init.headers)).not.toContain("gcp-test-token");
    expect(calls[0]?.init.headers).toMatchObject({ authorization: "Bearer gcp-test-token" });
    const createBody = JSON.parse(String(calls[0]?.init.body));
    expect(createBody.networkInterfaces[0]).not.toHaveProperty("accessConfigs");
    expect(createBody.tags.items).toContain("cmux-vm");

    const endpoint = await provider.openSSH(created.providerVmId, local);
    expect(endpoint.host).toBe("gcp-iap");
    expect(endpoint.proxy).toEqual({
      kind: "gcp-iap",
      project: "manaflow-437420",
      zone: "us-west1-b",
      instance: expect.any(String),
      port: 22,
    });
    expect(endpoint.credential.kind).toBe("authorizedKey");
    await provider.pause(created.providerVmId, local);
    await provider.destroy(created.providerVmId, local);
    expect(calls.map((call) => call.url)).toEqual([
      expect.stringContaining("/instances"),
      expect.stringContaining("/instances/"),
      expect.stringContaining("/instances/"),
      expect.stringContaining("/instances/"),
      expect.stringContaining("/instances/"),
    ]);
  });

  test("refuses an expired token before touching Compute Engine", async () => {
    let requests = 0;
    const provider = new GcpProvider({ fetch: async () => { requests += 1; return json({}); }, now: () => now });
    await expect(provider.create({
      image: "projects/manaflow-437420/global/images/cmux-linux",
      providerCredential: credential({ expiresAtUnix: Math.floor(now / 1000) }),
    })).rejects.toThrow(/expired/);
    expect(requests).toBe(0);
  });
});
