import { describe, expect, test } from "bun:test";
import { Freestyle } from "freestyle";
import { FreestyleProvider } from "../services/vms/drivers/freestyle";
import { freestyleCustomerId } from "../services/vms/drivers/freestyleCustomer";

// https://github.com/manaflow-ai/cmux/issues/27667: every machine names its
// owning account as its Freestyle customer. These run the real SDK against a
// recording fetch, so they pin the HTTP body Freestyle receives.

const VM_ID = "vm-d05087e5773e4a978036fc806b0cd759";
const OWNER = { customerId: "8f3c1e2a-4b5d-4e6f-8a7b-9c0d1e2f3a4b" };

type Sent = { readonly method: string; readonly path: string; readonly body: Record<string, unknown> | null };

function recordingFreestyle(vm: { readonly customerId?: string; readonly failUpdate?: boolean } = {}) {
  const sent: Sent[] = [];
  const fetch = (async (input: string | URL | Request, init?: RequestInit) => {
    const url = new URL(typeof input === "string" ? input : input instanceof URL ? input.href : input.url);
    const method = (init?.method ?? "GET").toUpperCase();
    const body = typeof init?.body === "string" ? JSON.parse(init.body) as Record<string, unknown> : null;
    sent.push({ method, path: url.pathname, body });
    if (method === "PATCH" && vm.failUpdate) {
      return Response.json({ code: "BAD_REQUEST", message: "bad request" }, { status: 400 });
    }
    return Response.json({
      id: VM_ID,
      state: "running",
      metadata: {},
      vpcs: [],
      networks: [],
      firewallRules: [],
      tlsRules: [],
      ...(vm.customerId ? { customerId: vm.customerId } : {}),
    });
  }) as typeof globalThis.fetch;
  const client = new Freestyle({ apiKey: "test-key", baseUrl: "https://freestyle.test", fetch });
  const provider = new FreestyleProvider({ client: () => client });
  return { provider, sent };
}

const creates = (sent: readonly Sent[]) => sent.filter((call) => call.method === "POST" && call.path === "/v5/vms");
const updates = (sent: readonly Sent[]) => sent.filter((call) => call.method === "PATCH" && call.path === `/v5/vms/${VM_ID}`);

describe("Freestyle customer tag", () => {
  test.each([
    ["create", (provider: FreestyleProvider) => provider.create({ image: "sh-image", customer: OWNER })],
    ["restore", (provider: FreestyleProvider) => provider.restore("sh-snapshot", { customer: OWNER })],
  ] as const)("%s sends the owner as the VM's customer", async (_name, run) => {
    const { provider, sent } = recordingFreestyle();
    await run(provider);
    const [create] = creates(sent);
    expect(create?.body?.customer).toEqual(OWNER);
    // An inline upsert and a customer reference are mutually exclusive.
    expect(create?.body).not.toHaveProperty("customerId");
    expect(create?.body?.metadata).toMatchObject({ cmux: "cloud" });
  });

  test("an id Freestyle would refuse is left out instead of failing the create", async () => {
    for (const customer of [undefined, { customerId: "" }, { customerId: "has space" }, { customerId: "x".repeat(129) }, { customerId: "deleted-account" }]) {
      const { provider, sent } = recordingFreestyle();
      await provider.create({ image: "sh-image", customer });
      expect(creates(sent)).toHaveLength(1);
      expect(creates(sent)[0]?.body).not.toHaveProperty("customer");
    }
  });

  test("accepts Freestyle's whole id alphabet", () => {
    expect(freestyleCustomerId({ customerId: " user_1.a:b@c-d " })).toBe("user_1.a:b@c-d");
    expect(freestyleCustomerId({ customerId: "x".repeat(128) })).toHaveLength(128);
  });

  test("resume tags a machine that has no customer yet", async () => {
    const { provider, sent } = recordingFreestyle();
    const handle = await provider.resume(VM_ID, { customer: OWNER });
    expect(handle.status).toBe("running");
    expect(updates(sent).map((call) => call.body)).toEqual([{ customer: OWNER }]);
  });

  test("resume leaves an already tagged machine alone", async () => {
    const { provider, sent } = recordingFreestyle({ customerId: OWNER.customerId });
    await provider.resume(VM_ID, { customer: OWNER });
    expect(updates(sent)).toEqual([]);
  });

  test("resume retags a machine whose customer is not its owner", async () => {
    const { provider, sent } = recordingFreestyle({ customerId: "someone-else" });
    await provider.resume(VM_ID, { customer: OWNER });
    expect(updates(sent).map((call) => call.body)).toEqual([{ customer: OWNER }]);
  });

  test("a refused tag never fails the wake", async () => {
    const { provider, sent } = recordingFreestyle({ failUpdate: true });
    const handle = await provider.resume(VM_ID, { customer: OWNER });
    expect(handle.status).toBe("running");
    expect(updates(sent)).toHaveLength(1);
  });

  test("resume without an owner sends no tag", async () => {
    const { provider, sent } = recordingFreestyle();
    await provider.resume(VM_ID);
    expect(updates(sent)).toEqual([]);
  });
});
