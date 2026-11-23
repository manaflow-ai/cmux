import { describe, expect, test } from "bun:test";
import { pageError } from "../shared/pageClient";
import { AppsOps } from "./types";
import { MockAppsProvider, sampleApps } from "./mockProvider";
import { AppsStore } from "./store";
import { userMessage } from "../shared/userMessage";

/** What a failure without its own sentence says (the owner's text stays in the error). */
const GENERIC = userMessage(undefined);

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
    expect(store.getSnapshot().updatesError).toBe(GENERIC);
    store.stop();
  });

  test("falls back cleanly when an older owner does not expose updates.list", async () => {
    const provider = new MockAppsProvider();
    provider.failNext(AppsOps.updatesList, pageError("cmux.protocol.unknown_op", AppsOps.updatesList));
    const store = new AppsStore(provider);

    await store.start();

    expect(store.getSnapshot().updates.map((update) => update.app)).toEqual(["cmux.github-prs"]);
    expect(store.getSnapshot().updatesStale).toBe(true);
    expect(store.getSnapshot().updatesError).toBe(userMessage(pageError("cmux.protocol.unknown_op", "")));
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

  test("does not let an older update response replace a newer refresh", async () => {
    const provider = new MockAppsProvider();
    const originalCall = provider.call.bind(provider);
    let releaseFirst: (() => void) | undefined;
    const firstResponse = new Promise<void>((resolve) => {
      releaseFirst = resolve;
    });
    let delayNext = false;
    provider.call = async <R>(op: string, params: unknown): Promise<R> => {
      if (op === AppsOps.updatesList && delayNext) {
        delayNext = false;
        const response = await originalCall<R>(op, params);
        await firstResponse;
        return response;
      }
      return originalCall<R>(op, params);
    };
    const store = new AppsStore(provider);
    await store.start();

    delayNext = true;
    const stale = store.refreshUpdates();
    const github = provider.installed["cmux.github-prs"];
    if (!github) throw new Error("sample app missing");
    github.update = { version: "1.3.0" };
    await store.refreshUpdates();
    if (!releaseFirst) throw new Error("first update request did not start");
    releaseFirst();
    await stale;

    expect(store.getSnapshot().updates[0]?.version).toBe("1.3.0");
    store.stop();
  });
});

describe("AppsStore double-clicked mutations", () => {
  // Leo, 2026-11-16: the install button shows a second confirm dialog. Each call to the host asks
  // for its own native confirmation, so a second click while the first sheet loads must join it.
  test("a second Install while the first waits on its confirmation sends one install", async () => {
    const provider = new MockAppsProvider();
    const originalCall = provider.call.bind(provider);
    let confirm: (() => void) | undefined;
    const confirmed = new Promise<void>((resolve) => {
      confirm = resolve;
    });
    provider.call = async <R>(op: string, params: unknown): Promise<R> => {
      if (op === AppsOps.install) await confirmed;
      return originalCall<R>(op, params);
    };
    const store = new AppsStore(provider);
    await store.start();
    const app = Object.values(provider.details).find((candidate) => !provider.installed[candidate.id]);
    if (!app) throw new Error("no uninstalled sample app");

    const first = store.install(app.id);
    const second = store.install(app.id);
    if (!confirm) throw new Error("install did not start");
    confirm();
    await Promise.all([first, second]);

    expect(provider.calls.filter((call) => call.op === AppsOps.install)).toHaveLength(1);
    await store.install(app.id);
    expect(provider.calls.filter((call) => call.op === AppsOps.install)).toHaveLength(2);
    store.stop();
  });
});

describe("AppsStore deep link after a catalog failure", () => {
  test("a deep-linked app does not stay Loading when the catalog load fails", async () => {
    const provider = new MockAppsProvider();
    provider.failNext(AppsOps.catalogList, new Error("supervisor unavailable"));
    const store = new AppsStore(provider, "#/discover?app=cmux.github-prs");

    await store.start();

    expect(store.getSnapshot().catalogStatus).toBe("error");
    expect(store.getSnapshot().selection).toBe("cmux.github-prs");
    expect(store.getSnapshot().detailStatus).toBe("error");
    store.stop();
  });

  test("without a client a deep link is idle, not loading", () => {
    const store = new AppsStore(null, "#/discover?app=cmux.github-prs");
    expect(store.getSnapshot().detailStatus).toBe("idle");
  });
});

describe("AppsStore shelves", () => {
  // Leo, 2026-11-16: "idk if we want to ship THOSE as standard apps". Discover lists the store
  // shelf; the SDK examples only when the owner offers them; a `cmux ext dev` app never.
  const shelved = (examples: boolean) => {
    const data = sampleApps();
    data.details["acme.caffeinate"]!.shelf = "example";
    data.details["someone.weather"]!.shelf = "local";
    return new MockAppsProvider({ ...data, examples });
  };
  const ids = (store: AppsStore) => store.getSnapshot().visible.map((app) => app.id);

  test("Discover shows only the store shelf, and a developer's Examples shows only the examples", async () => {
    const store = new AppsStore(shelved(true), "#/discover");
    await store.start();
    expect(ids(store)).toEqual(["cmux.github-prs", "cmux.coderouter"]);
    expect(store.getSnapshot().examplesOffered).toBe(true);

    store.setShelf("example");
    expect(ids(store)).toEqual(["acme.caffeinate"]);
    expect(store.getSnapshot().categories).toEqual(["productivity"]);
    store.setShelf("store");
    expect(ids(store)).toEqual(["cmux.github-prs", "cmux.coderouter"]);
    store.stop();
  });

  test("without the owner's offer, Examples never opens, even from a deep link", async () => {
    const store = new AppsStore(shelved(false), "#/discover?shelf=examples");
    await store.start();
    expect(store.getSnapshot().shelf).toBe("store");
    store.setShelf("example");
    expect(ids(store)).toEqual(["cmux.github-prs", "cmux.coderouter"]);
    store.stop();
  });

  test("a listing from an owner older than shelves stays on Discover", async () => {
    const store = new AppsStore(new MockAppsProvider(), "#/discover");
    await store.start();
    expect(ids(store)).toContain("someone.weather");
    store.stop();
  });
});
