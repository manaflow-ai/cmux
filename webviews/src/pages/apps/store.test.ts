import { describe, expect, test } from "bun:test";
import { pageError } from "../shared/pageClient";
import { AppsOps } from "./types";
import { MockAppsProvider } from "./mockProvider";
import { AppsStore } from "./store";

describe("AppsStore update center", () => {
  test("projects supervisor updates into installed state", async () => {
    const provider = new MockAppsProvider();
    const store = new AppsStore(provider, "#/installed");

    await store.start();

    expect(store.getSnapshot().updates).toEqual([
      {
        app: "cmux.github-prs",
        name: "GitHub PRs",
        current_version: "1.1.0",
        version: "1.2.0",
      },
    ]);
    expect(store.getSnapshot().installed[0]?.update).toEqual({ version: "1.2.0" });
    expect(provider.calls.some((call) => call.op === AppsOps.updatesList)).toBe(true);
    store.stop();
  });

  test("keeps installed update data visibly stale when updates.list fails", async () => {
    const provider = new MockAppsProvider();
    provider.failNext(AppsOps.updatesList, new Error("update service unavailable"));
    const store = new AppsStore(provider);

    await store.start();

    expect(store.getSnapshot().updates).toHaveLength(1);
    expect(store.getSnapshot().updatesStale).toBe(true);
    expect(store.getSnapshot().updatesError).toBe("update service unavailable");
    store.stop();
  });

  test("falls back cleanly when an older owner does not expose updates.list", async () => {
    const provider = new MockAppsProvider();
    provider.failNext(AppsOps.updatesList, pageError("cmux.protocol.unknown_op", AppsOps.updatesList));
    const store = new AppsStore(provider);

    await store.start();

    expect(store.getSnapshot().updates.map((update) => update.app)).toEqual(["cmux.github-prs"]);
    expect(store.getSnapshot().updatesStale).toBe(true);
    expect(store.getSnapshot().updatesError).toContain(AppsOps.updatesList);
    store.stop();
  });

  test("updates through the owner and clears the queue after rereading", async () => {
    const provider = new MockAppsProvider();
    const store = new AppsStore(provider);
    await store.start();

    await store.update("cmux.github-prs");

    expect(store.getSnapshot().updates).toEqual([]);
    expect(store.getSnapshot().installed.find((app) => app.id === "cmux.github-prs")?.version).toBe("1.2.0");
    const updateCall = provider.calls.find((call) => call.op === AppsOps.update);
    expect(updateCall?.key).toMatch(/^pg_[0-9a-f]{32}$/);
    store.stop();
  });
});
