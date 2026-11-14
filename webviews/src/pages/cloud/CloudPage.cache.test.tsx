// The Cloud page draws its last known machines in the first frame and keeps them on screen through a
// link drop (Leo, 2026-11-14: "i also want all our connectivity stuff to shut the fuck up and load
// faster/percievably load faster / whatever it takes"): a kept list before the owner answers, the
// owner's list in its place once it does, and a drop that says one line above the list only once it
// lasts, then comes back on its own.
import { act } from "react";
import { afterAll, expect, jest, test } from "bun:test";
import { JSDOM } from "jsdom";
import { LASTING_MS } from "../../ui/lasting";
import { createStrings } from "../shared/i18n";
import { CloudPage } from "./CloudPage";
import table from "./generated/strings.json";
import { MockCloudProvider, sampleMachines } from "./mockProvider";
import { CloudOps } from "./ops";
import { CLOUD_RESTART_MIN_MS, CloudStore } from "./store";
import { teardownDom } from "../../../test/support/domTeardown";

const dom = new JSDOM("<!doctype html><html><body></body></html>", { url: "http://localhost/" });
const globals = globalThis as Record<string, unknown>;
const replacements = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  IS_REACT_ACT_ENVIRONMENT: true,
};
const saved = Object.keys(replacements).map((key) => [key, key in globals, globals[key]] as const);
Object.assign(globals, replacements);
const { createRoot } = await import("react-dom/client");
const strings = createStrings(table);
const settle = async () => {
  for (let i = 0; i < 12; i++) await Promise.resolve();
};

afterAll(async () => {
  jest.useRealTimers();
  await teardownDom(saved, { window: dom.window, scope: globals });
});

/** The key and shape the page keeps its list under (machineCache.ts), written raw so the test reads the format. */
const KEY = "cmux.cloud.machines.v1";

class MemoryStorage {
  readonly items = new Map<string, string>();
  getItem(key: string): string | null {
    return this.items.get(key) ?? null;
  }
  setItem(key: string, value: string): void {
    this.items.set(key, value);
  }
  removeItem(key: string): void {
    this.items.delete(key);
  }
}

function keptList(team: string, names: string[]): MemoryStorage {
  const storage = new MemoryStorage();
  const machines = names.map((name, index) => ({ ...sampleMachines()[0], id: `vm_kept${index}`, name }));
  storage.setItem(KEY, JSON.stringify({ team, machines, revision: 1 }));
  return storage;
}

/** A provider whose account read never answers: the page stays before its first answer. */
class SilentAuthProvider extends MockCloudProvider {
  override async call<R>(op: string, params: unknown): Promise<R> {
    if (op === CloudOps.authStatus) return new Promise<R>(() => undefined);
    return super.call<R>(op, params);
  }
}

async function render(store: CloudStore) {
  const rootElement = document.createElement("div");
  document.body.append(rootElement);
  const root = createRoot(rootElement);
  await act(async () => root.render(<CloudPage store={store} strings={strings} />));
  const titles = () =>
    [...rootElement.querySelectorAll(".cloud-machine-title")].map((element) => element.textContent ?? "");
  const unmount = async () => {
    await act(async () => root.unmount());
    rootElement.remove();
  };
  return { rootElement, titles, unmount };
}

test("a kept list shows in the first frame, before the owner answers", async () => {
  const store = new CloudStore(new SilentAuthProvider(), {
    cache: keptList("team_personal", ["kept-one", "kept-two"]),
  });
  const page = await render(store);
  try {
    // No timers and no answer: this is the frame the page opens with.
    expect(page.titles()).toEqual(["kept-one", "kept-two"]);
    expect(page.rootElement.querySelector(".cloud-loading")).toBeNull();
  } finally {
    await page.unmount();
  }
});

test("the owner's list replaces the kept one in place, and is kept for the next open", async () => {
  const storage = keptList("team_personal", ["kept-one"]);
  const store = new CloudStore(new MockCloudProvider(), { cache: storage });
  const page = await render(store);
  try {
    expect(page.titles()).toEqual(["kept-one"]);
    await act(settle);
    const owner = sampleMachines().map((machine) => machine.name);
    expect(page.titles()).toEqual(owner);
    const kept = JSON.parse(storage.getItem(KEY)!) as { team: string; machines: Array<{ name: string }> };
    expect(kept.team).toBe("team_personal");
    expect(kept.machines.map((machine) => machine.name)).toEqual(owner);
  } finally {
    await page.unmount();
  }
});

test("a kept list of another team, or of a signed-out account, never stays", async () => {
  for (const signedIn of [true, false]) {
    const storage = keptList("team_other", ["not-yours"]);
    const store = new CloudStore(new MockCloudProvider({ signedIn }), { cache: storage });
    const page = await render(store);
    try {
      await act(settle);
      expect(page.titles()).not.toContain("not-yours");
      if (!signedIn) expect(storage.getItem(KEY)).toBeNull();
    } finally {
      await page.unmount();
    }
  }
});

test("a link drop keeps the list on screen, says one line only once it lasts, and comes back on its own", async () => {
  jest.useFakeTimers();
  const provider = new MockCloudProvider();
  const store = new CloudStore(provider);
  const page = await render(store);
  try {
    await act(settle);
    const owner = sampleMachines().map((machine) => machine.name);
    expect(page.titles()).toEqual(owner);
    // The link drops under a read the page makes (a machine's detail).
    provider.offline = true;
    await act(async () => {
      await store.select(owner.length ? sampleMachines()[0].id : undefined);
      await settle();
    });
    expect(store.getSnapshot().connection).toBe("disconnected");
    // Under the grace: the list as it was, and no word about the link.
    expect(page.titles()).toEqual(owner);
    expect(page.rootElement.querySelector(".cloud-disconnected")).toBeNull();
    expect(page.rootElement.querySelector(".cloud-disconnected-line")).toBeNull();
    // Past it: one line above the same list.
    await act(async () => {
      jest.advanceTimersByTime(LASTING_MS);
      await settle();
    });
    expect(page.titles()).toEqual(owner);
    expect(page.rootElement.querySelectorAll(".cloud-disconnected-line").length).toBe(1);
    expect(page.rootElement.querySelector(".cloud-disconnected")).toBeNull();
    // The link is back: the page reads again by itself, with no Retry, and the line goes.
    provider.offline = false;
    await act(async () => {
      for (let wait = 0; wait < 6 && store.getSnapshot().connection !== "connected"; wait++) {
        jest.advanceTimersByTime(CLOUD_RESTART_MIN_MS * 2 ** wait);
        await settle();
      }
    });
    expect(store.getSnapshot().connection).toBe("connected");
    expect(page.titles()).toEqual(owner);
    expect(page.rootElement.querySelector(".cloud-disconnected-line")).toBeNull();
  } finally {
    await page.unmount();
    jest.useRealTimers();
  }
});

test("a machine event that proves the link is back takes the drop's words with it", async () => {
  jest.useFakeTimers();
  const provider = new MockCloudProvider();
  const store = new CloudStore(provider);
  const page = await render(store);
  try {
    await act(settle);
    provider.offline = true;
    await act(async () => {
      await store.select(sampleMachines()[0].id);
      await settle();
    });
    expect(store.getSnapshot().connection).toBe("disconnected");
    provider.offline = false;
    // The owner's next event arrives before the page's own re-read.
    await act(async () => {
      provider.emitUpsert({ ...sampleMachines()[0], name: "api-dev-renamed" });
      await settle();
    });
    expect(store.getSnapshot().connection).toBe("connected");
    expect(store.getSnapshot().error).toBeUndefined();
    expect(page.rootElement.querySelector(".cloud-error")).toBeNull();
  } finally {
    await page.unmount();
    jest.useRealTimers();
  }
});
