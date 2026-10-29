import { describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";

import { vmCreateDisabledReason } from "../services/vms/config";
import { GcpProvider } from "../services/vms/drivers/gcp";
import { ProviderCreateCleanupError } from "../services/vms/drivers/providerCreateCleanup";
import { SecretBytes, type CreateOptions, type ProviderCredential } from "../services/vms/drivers/types";
import { isProviderDeletionConfirmed, isProviderNotFoundError } from "../services/vms/providerErrors";
import { gcpCredentialFromRequest, wipeProviderCredential } from "../services/vms/routeInput";
import { releaseProviderCredential } from "../services/vms/workflows";

const now = 1_735_689_600_000;
/** A key file shape (with its newlines); the body is not a real key. */
const TEST_PRIVATE_KEY = "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQ==\n-----END OPENSSH PRIVATE KEY-----\n";
const labsOn = { CMUX_VM_GCP_LABS_ENABLED: "1", CMUX_VM_GCP_ENABLED: "1" };

function credential(overrides: Partial<ProviderCredential> = {}): ProviderCredential {
  return {
    provider: "gcp",
    accessToken: new SecretBytes(new TextEncoder().encode("gcp-test-token")),
    expiresAtUnix: Math.floor(now / 1000) + 300,
    ...overrides,
  };
}

/** A cleanup intent that records what the driver named and whether it released it. */
function intent(record: (providerVmId: string) => Promise<void> = async () => {}) {
  const recorded: string[] = [];
  let released = 0;
  const options: NonNullable<CreateOptions["createCleanupIntent"]> = {
    record: async (providerVmId) => {
      await record(providerVmId);
      recorded.push(providerVmId);
    },
    released: () => { released += 1; },
  };
  return { options, recorded, released: () => released };
}

/** A create that passes every pre-insert check. */
function createOptions(cleanup?: ReturnType<typeof intent>, overrides: Partial<CreateOptions> = {}): CreateOptions {
  return {
    image: "projects/manaflow-437420/global/images/cmux-linux",
    network: { id: "projects/manaflow-437420/global/networks/cmux-vms" },
    providerCredential: credential({
      sshPublicKey: "ssh-ed25519 AAAA test",
      sshPrivateKeyPem: new SecretBytes(new TextEncoder().encode("PRIVATE KEY")),
    }),
    ...(cleanup ? { createCleanupIntent: cleanup.options } : {}),
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

  test("an SSH private key header is a base64 key file; anything else refuses the credential", () => {
    const parse = (key: string) => gcpCredentialFromRequest(new Request("https://cmux.test", {
      headers: { "x-cmux-gcp-access-token": "local-token", "x-cmux-gcp-ssh-private-key": key },
    }));
    expect(parse(Buffer.from(TEST_PRIVATE_KEY).toString("base64"))?.sshPrivateKeyPem?.utf8()).toBe(TEST_PRIVATE_KEY);
    expect(parse("-----BEGIN OPENSSH PRIVATE KEY----- b3Bl")).toBeUndefined();
    expect(parse(Buffer.from("not a key").toString("base64"))).toBeUndefined();
    // 32 KiB decoded is the limit; one byte more is refused.
    const keyOfSize = (size: number) => Buffer.concat([Buffer.from(TEST_PRIVATE_KEY), Buffer.alloc(size - TEST_PRIVATE_KEY.length, 0x41)]).toString("base64");
    expect(parse(keyOfSize(32_768))?.sshPrivateKeyPem?.byteLength).toBe(32_768);
    expect(parse(keyOfSize(32_769))).toBeUndefined();
  });

  test("a workflow holds the credential until it ends, then wipes it", async () => {
    const parse = () => gcpCredentialFromRequest(new Request("https://cmux.test", {
      headers: {
        "x-cmux-gcp-access-token": "local-token",
        "x-cmux-gcp-ssh-private-key": Buffer.from(TEST_PRIVATE_KEY).toString("base64"),
      },
    }));
    const live = parse();
    const program = Effect.sync(() => {
      expect(live?.accessToken.wiped).toBe(false);
      return live?.accessToken.utf8();
    }).pipe(releaseProviderCredential(live));
    // Building the program wipes nothing; running it to the end does.
    expect(live?.accessToken.wiped).toBe(false);
    // The header carries the key file in base64; the credential holds the file itself.
    expect(live?.sshPrivateKeyPem?.utf8()).toBe(TEST_PRIVATE_KEY);
    expect(await Effect.runPromise(program)).toBe("local-token");
    expect(live?.accessToken.wiped).toBe(true);
    expect(live?.sshPrivateKeyPem?.wiped).toBe(true);

    const failing = parse();
    await expect(Effect.runPromise(Effect.fail(new Error("provider failed")).pipe(releaseProviderCredential(failing))))
      .rejects.toThrow(/provider failed/);
    expect(failing?.accessToken.wiped).toBe(true);
  });

  test("a create that fails after the insert deletes the named instance", async () => {
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
    const confirmed = intent();
    await expect(cleaned.create(createOptions(confirmed))).rejects.toThrow(/returned 500/);
    expect(methods).toEqual(["POST", "GET", "DELETE"]);
    // A confirmed rollback releases the intent: the row owns nothing.
    expect(confirmed.recorded).toHaveLength(1);
    expect(confirmed.released()).toBe(1);

    const stuck = new GcpProvider({
      fetch: async () => json({}, 503),
      now: () => now,
      env: labsOn,
    });
    const retained = intent();
    const failure = await stuck.create(createOptions(retained)).catch((error: unknown) => error);
    expect(failure).toBeInstanceOf(ProviderCreateCleanupError);
    expect((failure as ProviderCreateCleanupError).providerVmId).toBe(retained.recorded[0]);
    expect(retained.released()).toBe(0);
  });

  test("only an insert with a known outcome lets a not-found rollback release the intent", async () => {
    const methods: string[] = [];
    const refused = intent();
    const refusing = new GcpProvider({
      fetch: async (_input, init) => { methods.push(String(init?.method)); return json({}, 403); },
      now: () => now,
      env: labsOn,
    });
    await expect(refusing.create(createOptions(refused))).rejects.toThrow(/returned 403/);
    expect(methods).toEqual(["POST"]);
    expect(refused.released()).toBe(1);

    // A conflict or throttle may follow an allocation: the intent stays.
    const conflicted = intent();
    const conflicting = new GcpProvider({
      fetch: async (_input, init) => init?.method === "POST" ? json({}, 409) : json({}, 404),
      now: () => now,
      env: labsOn,
    });
    const conflict = await conflicting.create(createOptions(conflicted)).catch((error: unknown) => error);
    expect(conflict).toBeInstanceOf(ProviderCreateCleanupError);
    expect(conflicted.released()).toBe(0);

    // The insert never answered: it may still land, so the 404 proves nothing.
    const unanswered = intent();
    const dropping = new GcpProvider({
      fetch: async (_input, init) => {
        if (init?.method === "POST") throw new Error("connection reset");
        return json({}, 404);
      },
      now: () => now,
      env: labsOn,
    });
    const failure = await dropping.create(createOptions(unanswered)).catch((error: unknown) => error);
    expect(failure).toBeInstanceOf(ProviderCreateCleanupError);
    expect(unanswered.released()).toBe(0);

    // Accepted but still running: the instance may not be visible yet.
    const running = intent();
    const pending = new GcpProvider({
      fetch: async (input, init) => {
        const path = new URL(String(input)).pathname;
        if (init?.method === "POST") return json({ name: "insert-op", status: "RUNNING", zone: "us-west1-b" });
        if (path.endsWith("/operations/insert-op")) return json({}, 500);
        return json({}, 404);
      },
      now: () => now,
      env: labsOn,
    });
    const unsettled = await pending.create(createOptions(running)).catch((error: unknown) => error);
    expect(unsettled).toBeInstanceOf(ProviderCreateCleanupError);
    expect(running.released()).toBe(0);

    // An unfinished insert with no operation name cannot be followed either.
    const nameless = intent();
    const malformed = new GcpProvider({
      fetch: async (_input, init) => init?.method === "POST" ? json({ status: "RUNNING" }) : json({}, 404),
      now: () => now,
      env: labsOn,
    });
    const unknown = await malformed.create(createOptions(nameless)).catch((error: unknown) => error);
    expect(unknown).toBeInstanceOf(ProviderCreateCleanupError);
    expect(nameless.released()).toBe(0);
  });

  test("a delete whose operation record is missing is confirmed only by reading the instance back", async () => {
    let instanceExists = true;
    const provider = new GcpProvider({
      fetch: async (input, init) => {
        const path = new URL(String(input)).pathname;
        if (init?.method === "DELETE") return json({ name: "delete-op", status: "RUNNING", zone: "us-west1-b" });
        if (path.endsWith("/operations/delete-op")) return json({}, 404);
        return instanceExists ? json({ name: "cmux-gcp", status: "STOPPING" }) : json({}, 404);
      },
      now: () => now,
      env: labsOn,
    });
    const vmId = "manaflow-437420/us-west1-b/cmux-gcp";
    const unconfirmed = await provider.destroy(vmId, credential()).catch((error: unknown) => error);
    expect(unconfirmed).toBeInstanceOf(Error);
    expect(isProviderDeletionConfirmed(unconfirmed)).toBe(false);
    expect(isProviderNotFoundError(unconfirmed)).toBe(false);
    instanceExists = false;
    await expect(provider.destroy(vmId, credential())).resolves.toBeUndefined();
  });

  test("a not-found delete is confirmed only once no operation on the instance is unfinished", async () => {
    let insertStatus = "RUNNING";
    const provider = new GcpProvider({
      fetch: async (input, init) => {
        const url = new URL(String(input));
        if (init?.method === "DELETE") return json({}, 404);
        if (url.pathname.endsWith("/operations")) {
          expect(url.searchParams.get("filter")).toBe("targetLink eq '.*/projects/manaflow-437420/zones/us-west1-b/instances/cmux-late'");
          return json({ items: [{ name: "insert-op", status: insertStatus }] });
        }
        return json({}, 404);
      },
      now: () => now,
      env: labsOn,
    });
    const vmId = "manaflow-437420/us-west1-b/cmux-late";
    const pending = await provider.destroy(vmId, credential()).catch((error: unknown) => error);
    expect(isProviderDeletionConfirmed(pending)).toBe(false);
    expect(isProviderNotFoundError(pending)).toBe(false);
    insertStatus = "DONE";
    const gone = await provider.destroy(vmId, credential()).catch((error: unknown) => error);
    expect(isProviderDeletionConfirmed(gone)).toBe(true);
  });

  test("create names its instance durably before the insert and sends nothing when it cannot", async () => {
    const requests: string[] = [];
    const provider = new GcpProvider({
      fetch: async (_input, init) => { requests.push(String(init?.method)); return json({ name: "op", status: "DONE" }); },
      now: () => now,
      env: labsOn,
    });
    await expect(provider.create(createOptions())).rejects.toThrow(/durable cleanup intent/);
    const refused = intent(async () => { throw new Error("row is no longer an open create"); });
    await expect(provider.create(createOptions(refused)))
      .rejects.toThrow(/could not record its cleanup intent/);
    expect(requests).toEqual([]);

    let insertedAfter: string[] = [];
    const ordered = intent(async () => { insertedAfter = [...requests]; });
    await provider.create(createOptions(ordered));
    expect(insertedAfter).toEqual([]);
    expect(requests[0]).toBe("POST");
    expect(ordered.recorded[0]).toMatch(/^manaflow-437420\/us-west1-b\/cmux-[0-9a-f]{12}$/);

    // A gate refusal records nothing; one that lands between the record and
    // the insert releases it, since nothing was sent.
    requests.length = 0;
    const env: Record<string, string> = {};
    const gated = new GcpProvider({
      fetch: async (_input, init) => { requests.push(String(init?.method)); return json({ name: "op", status: "DONE" }); },
      now: () => now,
      env,
    });
    const offIntent = intent();
    await expect(gated.create(createOptions(offIntent))).rejects.toThrow(/Labs/);
    expect(offIntent.recorded).toEqual([]);
    const flipped = intent(async () => { delete env["CMUX_VM_GCP_ENABLED"]; });
    Object.assign(env, labsOn);
    await expect(gated.create(createOptions(flipped))).rejects.toThrow(/Labs/);
    expect(flipped.recorded).toHaveLength(1);
    expect(flipped.released()).toBe(1);
    expect(requests).toEqual([]);
  });

  test("a create whose credential is wiped after the insert names the instance it could not delete", async () => {
    const sent: string[] = [];
    let inserted!: () => void;
    const insertAccepted = new Promise<void>((resolve) => { inserted = resolve; });
    const provider = new GcpProvider({
      fetch: (input, init) => {
        sent.push(`${init?.method} ${new URL(String(input)).pathname}`);
        if (init?.method === "POST") {
          inserted();
          return Promise.resolve(json({ name: "insert-op", status: "RUNNING", zone: "us-west1-b" }));
        }
        // The operation poll is in flight when the workflow ends.
        return new Promise<Response>((_resolve, reject) => {
          init?.signal?.addEventListener("abort", () => reject(new Error("aborted")));
        });
      },
      now: () => now,
      env: labsOn,
    });
    const local = credential({
      lifetime: new AbortController(),
      sshPublicKey: "ssh-ed25519 AAAA test",
      sshPrivateKeyPem: new SecretBytes(new TextEncoder().encode("PRIVATE KEY")),
    });
    const cleanup = intent();
    const creating = provider.create(createOptions(cleanup, { providerCredential: local })).catch((error: unknown) => error);
    await insertAccepted;
    wipeProviderCredential(local);
    const failure = await creating;
    expect(failure).toBeInstanceOf(ProviderCreateCleanupError);
    expect((failure as ProviderCreateCleanupError).providerVmId).toBe(cleanup.recorded[0]);
    expect(cleanup.released()).toBe(0);
    // The wiped token is never sent again, so no DELETE left the process.
    expect(sent.some((line) => line.startsWith("DELETE"))).toBe(false);
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
      if (calls.length === 2 || calls.length === 3) return json({
        name: "cmux-abc",
        status: "RUNNING",
        networkInterfaces: [{ networkIP: "10.0.0.4", accessConfigs: [{ natIP: "203.0.113.4" }] }],
      });
      return json({ name: `${calls.length}-op`, status: "DONE" });
    };
    const provider = new GcpProvider({ fetch, now: () => now, env: labsOn });
    const local = credential({
      sshPublicKey: "ssh-ed25519 AAAA test",
      sshPrivateKeyPem: new SecretBytes(new TextEncoder().encode(TEST_PRIVATE_KEY)),
    });
    const created = await provider.create({
      image: "projects/manaflow-437420/global/images/cmux-linux",
      displayName: "GCP Lab",
      providerMetadata: { project: "manaflow-437420", zone: "us-west1-b" },
      network: { id: "projects/manaflow-437420/global/networks/cmux-vms" },
      providerCredential: local,
      createCleanupIntent: intent().options,
    });
    expect(created.provider).toBe("gcp");
    expect(created.providerVmId).toMatch(/^manaflow-437420\/us-west1-b\//);
    expect(created.providerMetadata).not.toHaveProperty("accessToken");
    expect(JSON.stringify(created)).not.toContain("gcp-test-token");
    expect(String(calls[0]?.init.headers)).not.toContain("gcp-test-token");
    expect(calls[0]?.init.headers).toMatchObject({ authorization: "Bearer gcp-test-token" });
    const createBody = JSON.parse(String(calls[0]?.init.body));
    expect(createBody.networkInterfaces).toEqual([{
      network: "projects/manaflow-437420/global/networks/cmux-vms",
      subnetwork: "regions/us-west1/subnetworks/cmux-vms",
    }]);
    expect(createBody.tags.items).toContain("cmux-vm");
    expect(String(calls[0]?.init.body)).not.toContain("PRIVATE KEY");
    expect(String(calls[0]?.init.body)).not.toContain("b3BlbnNzaC1rZXktdjE");

    const endpoint = await provider.openSSH(created.providerVmId, local);
    expect(endpoint.host).toBe("gcp-iap");
    expect(endpoint.proxy).toEqual({
      kind: "gcp-iap",
      project: "manaflow-437420",
      zone: "us-west1-b",
      instance: expect.stringContaining("gcp-lab-"),
      port: 22,
    });
    expect(endpoint.credential).toEqual({ kind: "authorizedKey", privateKeyPem: TEST_PRIVATE_KEY });
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
    const provider = new GcpProvider({ fetch: async () => { requests += 1; return json({}); }, now: () => now, env: labsOn });
    await expect(provider.create({
      image: "projects/manaflow-437420/global/images/cmux-linux",
      providerCredential: credential({ expiresAtUnix: Math.floor(now / 1000) }),
    })).rejects.toThrow(/expired/);
    expect(requests).toBe(0);
  });

  test("provisions the private network idempotently: deny-all ingress, IAP-only SSH, NAT egress", async () => {
    const calls: { method: string; path: string; body?: Record<string, unknown> }[] = [];
    const selfLink = "https://www.googleapis.com/compute/v1/projects/user-project/global/networks/cmux-vms";
    const state: Record<string, Record<string, unknown> | undefined> = {
      // A concurrent request created the VPC between our read and our insert.
      network: undefined,
      // Drifted: someone disabled the deny rule.
      "cmux-vms-deny-ingress": { network: selfLink, direction: "INGRESS", priority: 1000, targetTags: ["cmux-vm"], denied: [{ IPProtocol: "all" }], disabled: true },
      // Drifted: someone lowered the NAT port allocation.
      router: { network: selfLink, nats: [{ name: "cmux-vms", natIpAllocateOption: "AUTO_ONLY", sourceSubnetworkIpRangesToNat: "ALL_SUBNETWORKS_ALL_IP_RANGES", minPortsPerVm: 32 }] },
    };
    let regionalPolls = 0;
    const provider = new GcpProvider({
      fetch: async (input, init) => {
        const method = String(init?.method ?? "GET");
        const path = new URL(String(input)).pathname.replace(/^\/compute\/v1/, "");
        const body = init?.body ? JSON.parse(String(init.body)) as Record<string, unknown> : undefined;
        calls.push({ method, path, ...(body ? { body } : {}) });
        const key = path.endsWith("/global/networks/cmux-vms") ? "network"
          : path.endsWith("/subnetworks/cmux-vms") ? "subnet"
          : path.endsWith("/routers/cmux-vms") ? "router"
          : path.split("/firewalls/")[1];
        // Reads come back normalized the way Compute Engine answers them.
        if (method === "GET" && key) return state[key] ? json({ sourceRanges: ["0.0.0.0/0"], disabled: false, ...state[key] }) : json({}, 404);
        if (method === "POST" && path.endsWith("/global/networks")) {
          state.network = { selfLink, autoCreateSubnetworks: false };
          return json({}, 409);
        }
        if (method === "POST" && path.endsWith("/subnetworks")) {
          state.subnet = { ipCidrRange: String(body?.ipCidrRange), network: String(body?.network) };
          return json({ name: "subnet-op", status: "RUNNING", region: "https://www.googleapis.com/compute/v1/projects/user-project/regions/europe-west4" });
        }
        if (path.endsWith("/regions/europe-west4/operations/subnet-op")) {
          regionalPolls += 1;
          return json({ name: "subnet-op", status: "DONE" });
        }
        if ((method === "POST" && path.endsWith("/global/firewalls")) || method === "PUT") {
          state[String(body?.name)] = body;
        }
        if (method === "PATCH" && key === "router") state.router = body;
        return json({ name: "op", status: "DONE" });
      },
      now: () => now,
      sleep: async () => {},
      env: labsOn,
    });
    await expect(provider.privateNetworking.ensureNetwork({ slug: "ignored" })).rejects.toThrow(/access token/);
    expect(calls).toEqual([]);

    const ensure = (providerRegion: string) => provider.privateNetworking.ensureNetwork({
      slug: "ignored",
      cidr: "10.250.16.0/20",
      providerCredential: credential(),
      providerProject: "user-project",
      providerRegion,
    });
    await expect(ensure("mars-north1")).rejects.toThrow(/not available/);
    expect(calls).toEqual([]);
    const network = await ensure("europe-west4");
    // Each region of the project-wide VPC has its own /20; the account range is not reused.
    expect(network).toEqual({ id: selfLink, slug: "cmux-vms", cidr: "10.209.80.0/20", cidrV6: null });
    // The subnet insert names its region in the path only, and its regional operation is followed.
    const subnet = calls.find((call) => call.method === "POST" && call.path.endsWith("/regions/europe-west4/subnetworks"));
    expect(subnet?.body).toEqual({ name: "cmux-vms", network: selfLink, ipCidrRange: "10.209.80.0/20" });
    expect(regionalPolls).toBe(1);
    // The disabled deny rule is replaced; the missing IAP rule is created.
    expect(calls.filter((call) => call.method === "PUT").map((call) => call.body)).toEqual([
      expect.objectContaining({ name: "cmux-vms-deny-ingress", denied: [{ IPProtocol: "all" }], sourceRanges: ["0.0.0.0/0"], disabled: false, targetTags: ["cmux-vm"] }),
    ]);
    expect(calls.filter((call) => call.method === "POST" && call.path.endsWith("/global/firewalls")).map((call) => call.body)).toEqual([
      expect.objectContaining({ name: "cmux-vms-iap-ssh", allowed: [{ IPProtocol: "tcp", ports: ["22"] }], sourceRanges: ["35.235.240.0/20"], priority: 900 }),
    ]);
    // The drifted NAT is patched back to the full configuration.
    expect(calls.filter((call) => call.path.includes("/routers") && call.method !== "GET").map((call) => [call.method, call.body?.nats])).toEqual([
      ["PATCH", [{ name: "cmux-vms", natIpAllocateOption: "AUTO_ONLY", sourceSubnetworkIpRangesToNat: "ALL_SUBNETWORKS_ALL_IP_RANGES", minPortsPerVm: 64 }]],
    ]);
    // A second run converges without changes.
    calls.length = 0;
    await ensure("europe-west4");
    expect(calls.every((call) => call.method === "GET")).toBe(true);

    // A same-named subnet or router on another VPC cannot be repaired in place.
    state.subnet = { ipCidrRange: "10.209.80.0/20", network: "https://www.googleapis.com/compute/v1/projects/user-project/global/networks/default" };
    await expect(ensure("europe-west4")).rejects.toThrow(/subnetworks\/cmux-vms exists on another network/);
    state.subnet = { ipCidrRange: "10.240.0.0/16", network: selfLink };
    await expect(ensure("europe-west4")).rejects.toThrow(/has range 10.240.0.0\/16, not 10.209.80.0\/20/);
    state.subnet = { ipCidrRange: "10.209.80.0/20", network: selfLink };
    state.router = { network: "projects/user-project/global/networks/default", nats: [] };
    await expect(ensure("europe-west4")).rejects.toThrow(/routers\/cmux-vms exists on another network/);
    // An auto-mode VPC of that name would put subnets we do not own behind the NAT.
    state.network = { selfLink, autoCreateSubnetworks: true };
    await expect(ensure("europe-west4")).rejects.toThrow(/networks\/cmux-vms is not a custom-mode VPC/);
  });
});
