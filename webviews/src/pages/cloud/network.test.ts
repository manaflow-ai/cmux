// Network, domain, publication, port and browser sections against the landed catalog (R71 C5, C6).
// The mock answers the server's shapes (first-party-apps/cloud/server/tests/fixtures) and refuses
// arguments the catalog does not list, like the server.
import { describe, expect, test } from "bun:test";
import { MockCloudProvider, sampleMachines } from "./mockProvider";
import { ACTION_RUN, CloudOps, HostActions, type CloudMachine } from "./ops";
import { CloudStore } from "./store";

const settle = () => new Promise((resolve) => setTimeout(resolve, 0));
const running = () => sampleMachines().find((machine) => machine.status === "running") as CloudMachine;

async function selected(provider = new MockCloudProvider({ unsupported: [] })) {
  let keys = 0;
  const store = new CloudStore(provider, { newKey: () => `k${++keys}` });
  store.subscribe(() => undefined);
  await store.start();
  await settle();
  await store.select(running().id);
  await settle();
  return { provider, store };
}

const ops = (provider: MockCloudProvider, op: string) => provider.calls.filter((call) => call.op === op);
const runs = (provider: MockCloudProvider) =>
  ops(provider, ACTION_RUN).map((call) => call.params as { action: string; args: Record<string, unknown> });

describe("Cloud detail on the network ops (C6)", () => {
  test("list ops parse the catalog's object answers", async () => {
    const { provider, store } = await selected();
    const detail = store.getSnapshot().detail!;
    expect(store.getSnapshot().error).toBeUndefined();
    expect(detail.domains?.map((domain) => domain.hostname)).toEqual(["example.test"]);
    expect(detail.domains?.[0].dnsInstructions?.[0].name).toBe("_cmux.example.test");
    expect(detail.publications?.map((publication) => publication.vmId)).toEqual([running().id]);
    expect(detail.publications?.[0].accessMode).toBe("personal");
    expect(detail.networks?.map((network) => network.id)).toEqual(["vpc-test01"]);
    expect(detail.firewall?.every((rule) => rule.destination.vmId === running().id)).toBe(true);
    expect(detail.firewall?.length).toBeGreaterThan(0);
    expect(ops(provider, CloudOps.firewallList)[0].params).toEqual({ machine: running().id });
    expect(ops(provider, CloudOps.publicationList)[0].params).toEqual({ machine: running().id });
  });

  test("the server serves the network ops now: nothing shows not available", async () => {
    const { store } = await selected(new MockCloudProvider());
    const { unavailable, error } = store.getSnapshot();
    for (const op of [CloudOps.domainList, CloudOps.publicationList, CloudOps.networkList, CloudOps.firewallList])
      expect(unavailable).not.toContain(op);
    expect(error).toBeUndefined();
  });

  test("publication delete sends {publication} only, through the native action", async () => {
    const { provider, store } = await selected();
    const publication = store.getSnapshot().detail!.publications![0];
    await store.detail.deletePublication(publication.id);
    expect(ops(provider, CloudOps.publicationDelete)).toEqual([]);
    expect(runs(provider).at(-1)).toEqual({
      action: CloudOps.publicationDelete,
      args: { publication: publication.id, idempotency_key: "k1" },
    });
    expect(store.getSnapshot().detail!.publications).toEqual([]);
    expect(store.getSnapshot().error).toBeUndefined();
  });

  test("publication create sends the access mode; public adds confirmPublic; both through the native action", async () => {
    const { provider, store } = await selected();
    await store.detail.createPublication(running().id, 5173, "personal");
    await store.detail.createPublication(running().id, 8080, "public");
    expect(ops(provider, CloudOps.publicationCreate)).toEqual([]);
    expect(runs(provider).slice(-2)).toEqual([
      {
        action: CloudOps.publicationCreate,
        args: { machine: running().id, port: 5173, accessMode: "personal", idempotency_key: "k1" },
      },
      {
        action: CloudOps.publicationCreate,
        args: { machine: running().id, port: 8080, accessMode: "public", confirmPublic: true, idempotency_key: "k2" },
      },
    ]);
    expect(store.getSnapshot().detail!.publications!.map((publication) => publication.port)).toEqual([3000, 5173, 8080]);
    expect(store.getSnapshot().error).toBeUndefined();
  });

  test("firewall create sends {source, destination, description} through the native action", async () => {
    const { provider, store } = await selected();
    const rule = {
      source: { cidr: "203.0.113.0/24" },
      destination: { vmId: running().id, port: 22, protocol: "tcp" as const },
      description: "office ssh",
    };
    await store.detail.createFirewallRule(rule);
    expect(ops(provider, CloudOps.firewallCreate)).toEqual([]);
    expect(runs(provider).at(-1)).toEqual({ action: CloudOps.firewallCreate, args: { ...rule, idempotency_key: "k1" } });
    expect(store.getSnapshot().detail!.firewall!.some((r) => r.description === "office ssh")).toBe(true);
    expect(store.getSnapshot().error).toBeUndefined();
  });

  test("firewall delete sends {rule} only", async () => {
    const { provider, store } = await selected();
    const rule = store.getSnapshot().detail!.firewall![0];
    await store.deleteFirewallRule(rule.id);
    expect(runs(provider).at(-1)).toEqual({
      action: CloudOps.firewallDelete,
      args: { rule: rule.id, idempotency_key: "k1" },
    });
    expect(store.getSnapshot().error).toBeUndefined();
  });

  test("domain verify sends the host name and shows the new state", async () => {
    const { provider, store } = await selected();
    await store.detail.verifyDomain("example.test");
    expect(ops(provider, CloudOps.domainVerify)[0].params).toEqual({ domain: "example.test", idempotency_key: "k1" });
    expect(store.getSnapshot().detail!.domains![0].verificationState).toBe("verified");
  });

  test("tunnel attach and key rotation run only as native actions", async () => {
    const { provider, store } = await selected();
    await store.detail.attachTunnel("vpc-test01");
    await store.detail.rotateTunnelKey();
    expect(ops(provider, CloudOps.tunnelAttach)).toEqual([]);
    expect(ops(provider, CloudOps.tunnelRotateKey)).toEqual([]);
    expect(runs(provider).map((run) => run.action)).toEqual([CloudOps.tunnelAttach, CloudOps.tunnelRotateKey]);
    expect(runs(provider)[0].args).toEqual({ network: "vpc-test01", idempotency_key: "k1" });
    expect(store.getSnapshot().error).toBeUndefined();
  });
});

describe("Cloud detail on ports and the browser route (C5)", () => {
  test("port forward shows the 127.0.0.1 local port the owner answered", async () => {
    const { provider, store } = await selected();
    expect(store.getSnapshot().detail!.ports).toEqual([]);
    await store.detail.forwardPort(running().id, 3000);
    expect(ops(provider, CloudOps.portForward)[0].params).toEqual({
      machine: running().id,
      port: 3000,
      idempotency_key: "k1",
    });
    const [forward] = store.getSnapshot().detail!.ports!;
    expect(forward).toMatchObject({ port: 3000, host: "127.0.0.1", state: "up" });
    expect(forward.localPort).toBeGreaterThan(1024);
  });

  test("port close removes the forward", async () => {
    const { provider, store } = await selected();
    await store.detail.forwardPort(running().id, 3000);
    await store.detail.closePort(running().id, 3000);
    expect(ops(provider, CloudOps.portClose)[0].params).toEqual({ machine: running().id, port: 3000, idempotency_key: "k2" });
    expect(store.getSnapshot().detail!.ports).toEqual([]);
  });

  test("open in browser shows the URL and asks the host for a proxied tab", async () => {
    const { provider, store } = await selected();
    await store.detail.openBrowser(running().id, 3000);
    const route = store.getSnapshot().detail!.browser!;
    expect(route.url).toBe("http://localhost:3000/");
    expect(ops(provider, CloudOps.browserOpen)[0].params).toEqual({
      machine: running().id,
      port: 3000,
      idempotency_key: "k1",
    });
    expect(runs(provider).at(-1)).toEqual({
      action: HostActions.browserTabOpen,
      args: { url: route.url, proxy: route.proxy },
    });
  });

  test("a host that cannot open a proxied tab yet: the URL stays, no error", async () => {
    const { store } = await selected(new MockCloudProvider());
    await store.detail.openBrowser(running().id, 3000);
    expect(store.getSnapshot().detail!.browser?.url).toBe("http://localhost:3000/");
    expect(store.getSnapshot().unavailable).toContain(HostActions.browserTabOpen);
    expect(store.getSnapshot().error).toBeUndefined();
  });
});
