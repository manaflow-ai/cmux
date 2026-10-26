import { describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";

import { vmCreateDisabledReason } from "../services/vms/config";
import { GcpProvider } from "../services/vms/drivers/gcp";
import { SecretBytes, type ProviderCredential } from "../services/vms/drivers/types";
import { gcpCredentialFromRequest, wipeProviderCredential } from "../services/vms/routeInput";
import { releaseProviderCredential } from "../services/vms/workflows";

const now = 1_735_689_600_000;
const labsOn = { CMUX_VM_GCP_LABS_ENABLED: "1", CMUX_VM_GCP_ENABLED: "1" };

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
    expect(vmCreateDisabledReason("gcp", { CMUX_VM_GCP_LABS_ENABLED: "1" })).toContain("Labs");
    expect(vmCreateDisabledReason("gcp", { CMUX_VM_GCP_ENABLED: "1" })).toContain("Labs");
    expect(vmCreateDisabledReason("gcp", labsOn)).toBeNull();
    expect(vmCreateDisabledReason("gcp", { CMUX_VM_GCP_LABS_ENABLED: "1", CMUX_VM_GCP_ENABLED: "0" })).toContain("gcp");
    expect(vmCreateDisabledReason("freestyle", {})).toBeNull();
  });

  test("with Labs off, no operation on an existing GCP machine reaches Compute Engine", async () => {
    let requests = 0;
    const provider = new GcpProvider({ fetch: async () => { requests += 1; return json({ status: "RUNNING" }); }, now: () => now, env: {} });
    const vmId = "manaflow-437420/us-west1-b/cmux-abc";
    await expect(provider.getStatus(vmId, { credential: credential() })).rejects.toThrow(/Labs/);
    await expect(provider.getPauseState(vmId, credential())).rejects.toThrow(/Labs/);
    await expect(provider.pause(vmId, credential())).rejects.toThrow(/Labs/);
    await expect(provider.resume(vmId, credential())).rejects.toThrow(/Labs/);
    await expect(provider.destroy(vmId, credential())).rejects.toThrow(/Labs/);
    expect(requests).toBe(0);
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
    expect(parsed?.accessToken.wiped).toBe(true);
    expect(parsed?.accessToken.utf8()).not.toContain("local-token");
    expect(parsed?.accessToken.utf8()).toMatch(/^\0+$/);
    expect(gcpCredentialFromRequest(new Request("https://cmux.test", {
      headers: { "x-cmux-gcp-access-token": "local-token" },
    }), "freestyle")).toBeUndefined();
  });

  test("a workflow holds the credential until it ends, then wipes it", async () => {
    const parse = () => gcpCredentialFromRequest(new Request("https://cmux.test", {
      headers: {
        "x-cmux-gcp-access-token": "local-token",
        "x-cmux-gcp-ssh-private-key": "PRIVATE KEY",
      },
    }));
    const live = parse();
    const program = Effect.sync(() => {
      expect(live?.accessToken.wiped).toBe(false);
      return live?.accessToken.utf8();
    }).pipe(releaseProviderCredential(live));
    // Building the program wipes nothing; running it to the end does.
    expect(live?.accessToken.wiped).toBe(false);
    expect(await Effect.runPromise(program)).toBe("local-token");
    expect(live?.accessToken.wiped).toBe(true);
    expect(live?.sshPrivateKeyPem?.wiped).toBe(true);

    const failing = parse();
    await expect(Effect.runPromise(Effect.fail(new Error("provider failed")).pipe(releaseProviderCredential(failing))))
      .rejects.toThrow(/provider failed/);
    expect(failing?.accessToken.wiped).toBe(true);
  });

  test("a create that fails after the insert deletes the named instance", async () => {
    const createInput = () => ({
      image: "projects/manaflow-437420/global/images/cmux-linux",
      network: { id: "projects/manaflow-437420/global/networks/cmux-vms" },
      providerCredential: credential({
        sshPublicKey: "ssh-ed25519 AAAA test",
        sshPrivateKeyPem: new SecretBytes(new TextEncoder().encode("PRIVATE KEY")),
      }),
    });
    const methods: string[] = [];
    const cleaned = new GcpProvider({
      fetch: async (_input, init) => {
        methods.push(String(init?.method));
        if (methods.length === 1) return json({ name: "insert-op", status: "RUNNING", zone: "us-west1-b" });
        if (methods.length === 2) return json({}, 500);
        return json({ name: "delete-op", status: "DONE" });
      },
      now: () => now,
      env: labsOn,
    });
    await expect(cleaned.create(createInput())).rejects.toThrow(/returned 500/);
    expect(methods).toEqual(["POST", "GET", "DELETE"]);

    const stuck = new GcpProvider({
      fetch: async () => json({}, 503),
      now: () => now,
      env: labsOn,
    });
    await expect(stuck.create(createInput())).rejects.toThrow(/could not be confirmed deleted/);
  });

  test("wiping the credential aborts a request still carrying it", async () => {
    let started!: () => void;
    const inFlight = new Promise<void>((resolve) => { started = resolve; });
    const provider = new GcpProvider({
      fetch: (_input, init) => new Promise<Response>((_resolve, reject) => {
        init?.signal?.addEventListener("abort", () => reject(new Error("aborted")));
        started();
      }),
      now: () => now,
      env: labsOn,
    });
    const local = credential({ lifetime: new AbortController() });
    const pausing = provider.pause("manaflow-437420/us-west1-b/cmux-abc", local);
    await inFlight;
    wipeProviderCredential(local);
    await expect(pausing).rejects.toThrow(/did not answer/);
  });

  test("refuses a wiped token before touching Compute Engine", async () => {
    let requests = 0;
    const provider = new GcpProvider({ fetch: async () => { requests += 1; return json({}); }, now: () => now, env: labsOn });
    const wiped = credential();
    wipeProviderCredential(wiped);
    await expect(provider.pause("manaflow-437420/us-west1-b/cmux-abc", wiped)).rejects.toThrow(/access token is required/);
    expect(requests).toBe(0);
  });

  test("create fails closed without a resolved private network or SSH key pair", async () => {
    let requests = 0;
    const provider = new GcpProvider({ fetch: async () => { requests += 1; return json({}); }, now: () => now, env: labsOn });
    await expect(provider.create({
      image: "projects/manaflow-437420/global/images/cmux-linux",
      providerCredential: credential({
        sshPublicKey: "ssh-ed25519 AAAA test",
        sshPrivateKeyPem: new SecretBytes(new TextEncoder().encode("PRIVATE KEY")),
      }),
    })).rejects.toThrow(/private network/);
    await expect(provider.create({
      image: "projects/manaflow-437420/global/images/cmux-linux",
      network: { id: "projects/manaflow-437420/global/networks/cmux-vms" },
      providerCredential: credential(),
    })).rejects.toThrow(/SSH public\/private key pair/);
    expect(requests).toBe(0);
  });

  test("creates, stops, connects, and deletes without persisting the token", async () => {
    const calls: Array<{ url: string; init: RequestInit }> = [];
    const fetch = async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
      calls.push({ url: String(input), init: init ?? {} });
      if (calls.length === 1) return json({ name: "insert-op", status: "DONE" });
      if (calls.length === 2) return json({
        name: "cmux-abc",
        status: "RUNNING",
        networkInterfaces: [{ networkIP: "10.0.0.4", accessConfigs: [{ natIP: "203.0.113.4" }] }],
      });
      return json({ name: `${calls.length}-op`, status: "DONE" });
    };
    const provider = new GcpProvider({ fetch, now: () => now, env: labsOn });
    const local = credential({
      sshPublicKey: "ssh-ed25519 AAAA test",
      sshPrivateKeyPem: new SecretBytes(new TextEncoder().encode("PRIVATE KEY")),
    });
    const created = await provider.create({
      image: "projects/manaflow-437420/global/images/cmux-linux",
      displayName: "GCP Lab",
      providerMetadata: { project: "manaflow-437420", zone: "us-west1-b" },
      network: { id: "projects/manaflow-437420/global/networks/cmux-vms" },
      providerCredential: local,
    });
    expect(created.provider).toBe("gcp");
    expect(created.providerVmId).toMatch(/^manaflow-437420\/us-west1-b\//);
    expect(created.providerMetadata).not.toHaveProperty("accessToken");
    expect(JSON.stringify(created)).not.toContain("gcp-test-token");
    expect(String(calls[0]?.init.headers)).not.toContain("gcp-test-token");
    expect(calls[0]?.init.headers).toMatchObject({ authorization: "Bearer gcp-test-token" });
    const insert = JSON.parse(String(calls[0]?.init.body)) as { networkInterfaces: Record<string, unknown>[] };
    expect(insert.networkInterfaces).toEqual([{ network: "projects/manaflow-437420/global/networks/cmux-vms" }]);
    expect(String(calls[0]?.init.body)).not.toContain("PRIVATE KEY");

    await expect(provider.openSSH(created.providerVmId, local)).rejects.toThrow(/private-network follow-up/);
    await provider.pause(created.providerVmId, local);
    await provider.destroy(created.providerVmId, local);
    expect(calls.map((call) => call.url)).toEqual([
      expect.stringContaining("/instances"),
      expect.stringContaining("/instances/"),
      expect.stringContaining("/instances/"),
      expect.stringContaining("/instances/"),
    ]);
  });

  test("refuses an expired token before touching Compute Engine", async () => {
    let requests = 0;
    const provider = new GcpProvider({ fetch: async () => { requests += 1; return json({}); }, now: () => now, env: labsOn });
    await expect(provider.create({
      image: "projects/manaflow-437420/global/images/cmux-linux",
      providerCredential: credential({ expiresAtUnix: Math.floor(now / 1000) }),
    })).rejects.toThrow(/expired/);
    expect(requests).toBe(0);
  });
});
