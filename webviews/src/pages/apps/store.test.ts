import { describe, expect, test } from "bun:test";
import { pageError } from "../shared/pageClient";
import { MockAppsProvider } from "./mockProvider";
import { AppsStore } from "./store";
import { AppsOps } from "./types";

const settle = () => new Promise((resolve) => setTimeout(resolve, 0));

async function started(hash = "") {
  const provider = new MockAppsProvider();
  const store = new AppsStore(provider, hash);
  store.subscribe(() => undefined);
  await store.start();
  await settle();
  return { provider, store };
}

describe("AppsStore", () => {
  test("loads the catalog and installed list and watches for changes", async () => {
    const { provider, store } = await started();
    const snap = store.getSnapshot();
    expect(snap.connection).toBe("connected");
    expect(snap.catalog.length).toBe(4);
    expect(snap.installed.map((app) => app.id)).toEqual(["cmux.github-prs"]);
    expect(provider.watcherCount).toBe(1);
  });

  test("query and category filter locally without a reload", async () => {
    const { provider, store } = await started();
    const calls = provider.calls.length;
    store.setQuery("awake");
    expect(store.getSnapshot().visible.map((app) => app.id)).toEqual(["acme.caffeinate"]);
    store.setQuery("");
    store.setCategory("agents");
    expect(store.getSnapshot().visible.map((app) => app.id)).toEqual(["cmux.coderouter"]);
    store.setCategory("agents");
    expect(store.getSnapshot().category).toBeUndefined();
    expect(provider.calls.length).toBe(calls);
  });

  test("a route app opens its detail; an installed app's grants load with it", async () => {
    const { store } = await started("#/discover?app=cmux.github-prs");
    expect(store.getSnapshot().detail?.id).toBe("cmux.github-prs");
    expect(store.getSnapshot().grants["cmux.github-prs"]?.scopes.length).toBe(2);
  });

  test("install goes to the owner, then the page shows the owner's state", async () => {
    const { provider, store } = await started();
    await store.install("acme.caffeinate");
    expect(provider.calls.find((call) => call.op === AppsOps.install)?.params).toEqual({
      app: "acme.caffeinate",
      grant_optional: false,
    });
    expect(store.getSnapshot().installed.map((app) => app.id)).toContain("acme.caffeinate");
    expect(store.getSnapshot().catalog.find((app) => app.id === "acme.caffeinate")?.installed).toBe(true);
  });

  test("enable, sandbox, grant and update send typed params to the owner", async () => {
    const { provider, store } = await started();
    await store.setEnabled("cmux.github-prs", false);
    await store.setSandboxed("cmux.github-prs", true);
    await store.setGranted("cmux.github-prs", "net:api.github.com", false);
    await store.update("cmux.github-prs");
    const sent = provider.calls.filter((call) =>
      [AppsOps.set, AppsOps.grantSet, AppsOps.update].includes(call.op as never),
    );
    expect(sent.map((call) => [call.op, call.params])).toEqual([
      [AppsOps.set, { app: "cmux.github-prs", enabled: false }],
      [AppsOps.set, { app: "cmux.github-prs", sandboxed: true }],
      [AppsOps.grantSet, { app: "cmux.github-prs", scope: "net:api.github.com", granted: false }],
      [AppsOps.update, { app: "cmux.github-prs" }],
    ]);
    const row = store.getSnapshot().installed[0];
    expect(row).toMatchObject({ enabled: false, sandboxed: true, version: "1.2.0" });
    expect(row.update).toBeUndefined();
  });

  test("logs follow the owner's stream with the app filter, capped", async () => {
    const { store } = await started();
    await store.toggleLogs("cmux.github-prs");
    expect(store.getSnapshot().logs["cmux.github-prs"]?.map((line) => line.level)).toEqual(["info", "warn"]);
    await store.toggleLogs("cmux.github-prs");
    expect(store.getSnapshot().logsShown).toBeUndefined();
  });

  test("a refusal shows its message and changes nothing", async () => {
    const { store } = await started();
    await store.setGranted("cmux.github-prs", "nope:scope", true);
    expect(store.getSnapshot().error).toBe("nope:scope");
  });

  test("a lost host shows disconnected; no client is disconnected from the start", async () => {
    const { provider, store } = await started();
    provider.offline = true;
    await store.reload();
    expect(store.getSnapshot().connection).toBe("disconnected");
    expect(new AppsStore(null).getSnapshot()).toMatchObject({ connection: "disconnected", loading: false });
  });

  test("a retried action reuses its idempotency key; a new action gets a new one", async () => {
    const { provider, store } = await started();
    provider.failNext(AppsOps.install, pageError("cmux.protocol.timeout", "timed out", true));
    await store.install("acme.caffeinate");
    expect(store.getSnapshot().error).toBe("timed out");
    // The person clicks Install again after the timeout: the same action, the same key.
    await store.install("acme.caffeinate");
    const installs = () => provider.calls.filter((call) => call.op === AppsOps.install).map((call) => call.key);
    expect(installs().length).toBe(2);
    expect(typeof installs()[0]).toBe("string");
    expect(installs()[1]).toBe(installs()[0]);
    await store.uninstall("acme.caffeinate");
    await store.install("acme.caffeinate");
    const uninstallKey = provider.calls.find((call) => call.op === AppsOps.uninstall)?.key;
    expect(new Set([installs()[0], uninstallKey, installs()[2]]).size).toBe(3);
    // Every mutation carries a key; reads and Open do not.
    for (const call of provider.calls) {
      const mutation = [AppsOps.install, AppsOps.uninstall, AppsOps.set, AppsOps.grantSet, AppsOps.update].includes(
        call.op as never,
      );
      expect(typeof call.key === "string").toBe(mutation);
    }
  });

  test("a refusal or a declined sheet ends the action: the next try is a new action", async () => {
    const { provider, store } = await started();
    provider.failNext(AppsOps.set, pageError("cmux.apps.origin", "needs a person", false));
    await store.setHidden("cmux.github-prs", true);
    provider.failNext(AppsOps.set, pageError("cmux.page.cancelled", "cancelled", false));
    await store.setHidden("cmux.github-prs", true);
    expect(store.getSnapshot().error).toBe("needs a person");
    await store.setHidden("cmux.github-prs", true);
    const keys = provider.calls.filter((call) => call.op === AppsOps.set).map((call) => call.key);
    expect(new Set(keys).size).toBe(3);
  });
});
