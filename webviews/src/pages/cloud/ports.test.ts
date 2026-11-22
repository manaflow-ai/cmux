// Ports and the browser route of the selected machine (server src/ports/ops.rs): this Mac's forwards
// on 127.0.0.1 and a proxy route the browser host opens in a CEF tab.
import { describe, expect, test } from "bun:test";
import { MockCloudProvider, sampleMachines } from "./mockProvider";
import { ACTION_RUN, CloudOps, HostActions } from "./ops";
import { CloudStore } from "./store";

const settle = () => new Promise((resolve) => setTimeout(resolve, 0));
const running = () => sampleMachines().find((machine) => machine.status === "running" && !machine.classic)!;

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

describe("Cloud detail on ports and the browser route", () => {
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
    expect(ops(provider, CloudOps.portClose)[0].params).toEqual({
      machine: running().id,
      port: 3000,
      idempotency_key: "k2",
    });
    expect(store.getSnapshot().detail!.ports).toEqual([]);
  });

  test("open in browser shows the URL and asks the host for a CEF tab with the machine store", async () => {
    const { provider, store } = await selected();
    await store.detail.openBrowser(running().id, 3000, "api-dev");
    const route = store.getSnapshot().detail!.browser!;
    expect(route.url).toBe("http://localhost:3000/");
    expect(ops(provider, CloudOps.browserOpen)[0].params).toEqual({
      machine: running().id,
      port: 3000,
      idempotency_key: "k1",
    });
    // The proxy rides the tab configuration's machine store, and only the CEF engine may load it.
    expect(runs(provider).at(-1)).toEqual({
      action: HostActions.browserTabOpen,
      args: {
        url: route.url,
        machineStore: { machine: running().id, machineName: "api-dev", proxy: route.proxy },
        engine: "cef",
      },
    });
  });

  test("a typed refusal of the proxied tab shows the message and never retries", async () => {
    const provider = new MockCloudProvider({ unsupported: [] });
    provider.tabError = "cmux.browser.proxy_refused";
    const { store } = await selected(provider);
    await store.detail.openBrowser(running().id, 3000, "api-dev");
    expect(runs(provider).filter((run) => run.action === HostActions.browserTabOpen).length).toBe(1);
    expect(store.getSnapshot().detail!.browserRefused).toBe(true);
    expect(store.getSnapshot().detail!.browser?.url).toBe("http://localhost:3000/");
    expect(store.getSnapshot().error).toBeUndefined();
  });

  test("a host that cannot open a proxied tab yet: the URL stays, no error", async () => {
    const { store } = await selected(new MockCloudProvider());
    await store.detail.openBrowser(running().id, 3000, "api-dev");
    expect(store.getSnapshot().detail!.browser?.url).toBe("http://localhost:3000/");
    expect(store.getSnapshot().unavailable).toContain(HostActions.browserTabOpen);
    expect(store.getSnapshot().detail!.browserRefused).toBeUndefined();
    expect(store.getSnapshot().error).toBeUndefined();
  });
});
