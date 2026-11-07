// Leo 2026-11-05: "Like literally with a click to a past nightly. Like that would be huge. Like just
// having that list of like, okay, you can just go and through the What's New page, you can just get
// back to a prior version if you wanted to." Each day's Versions lists its builds with their commit,
// their changes since the build before, and Install, which asks once before the app restarts.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import { SheetBuilds } from "../src/pages/changelog/SheetPage";
import { ChangelogStore, type ChangelogSnapshot } from "../src/pages/changelog/store";
import type { IndexEntry } from "../src/pages/changelog/types";
import type { PageClient } from "../src/pages/shared/pageClient";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "location", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { url: "cmux-page://cmux.changelog/" });
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    location: dom.window.location,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
});

afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const strings = {
  language: "en",
  t: (key: string) =>
    ({
      "changelog.page.current": "Installed",
      "changelog.build.install": "Install",
      "changelog.build.confirm": "Restart into it",
      "changelog.build.installing": "Checking…",
      "changelog.build.changes": "Changes",
    })[key] ?? key,
  format: (key: string) => key,
};

const builds: IndexEntry[] = [
  { build: "3", shortVersion: "1.0.0-nightly.3", date: "2026-11-05", highlights: 2, head: "c".repeat(40) },
  { build: "2", shortVersion: "1.0.0-nightly.2", date: "2026-11-05", highlights: 1, head: "b".repeat(40) },
  { build: "1", shortVersion: "1.0.0-nightly.1", date: "2026-11-04", highlights: 1 },
];

/** A host that records each call; `install` answers with `refusal` when set. */
function host(refusal?: string) {
  const calls: [string, unknown][] = [];
  const client = {
    call: async (op: string, params: unknown) => {
      calls.push([op, params]);
      if (op === "cmux.changelog.list") return { current: "3", builds };
      if (op === "cmux.changelog.installable") return { installs: true };
      if (op === "cmux.changelog.install" && refusal)
        throw Object.assign(new Error(refusal), { code: "cmux.page.refused" });
      return {};
    },
  } as unknown as PageClient;
  return { calls, store: new ChangelogStore(client) };
}

async function mount(store: ChangelogStore) {
  const { createRoot } = await import("react-dom/client");
  const element = document.getElementById("root")!;
  const root = createRoot(element);
  const draw = () =>
    root.render(
      <SheetBuilds
        builds={builds.slice(0, 2)}
        all={builds}
        s={store.getSnapshot() as ChangelogSnapshot}
        store={store}
        strings={strings as never}
      />,
    );
  store.subscribe(() => act(draw));
  act(draw);
  const row = (build: string) => element.querySelector(`[data-build="${build}"]`)!;
  return { root, row };
}

test("each build shows its commit, its changes since the build before, and Install unless it runs", async () => {
  const { store } = host();
  await store.start();
  await store.firstScreen();
  const { root, row } = await mount(store);
  expect(row("3").textContent).toContain("Installed");
  expect(row("3").querySelector("button")).toBeNull();
  const links = [...row("2").querySelectorAll("a")].map((a) => a.getAttribute("href"));
  expect(links).toEqual([
    `https://github.com/manaflow-ai/cmux/commit/${"b".repeat(40)}`,
    // Build 1 has no head (an older index): no compare link for build 2.
  ]);
  const newest = [...row("3").querySelectorAll("a")].map((a) => a.getAttribute("href"));
  expect(newest).toContain(`https://github.com/manaflow-ai/cmux/compare/${"b".repeat(40)}...${"c".repeat(40)}`);
  expect(row("2").querySelector("button")?.textContent).toBe("Install");
  act(() => root.unmount());
});

test("Install asks once, then the host restarts into that build", async () => {
  const { calls, store } = host();
  await store.start();
  await store.firstScreen();
  const { root, row } = await mount(store);
  act(() => row("2").querySelector("button")!.click());
  expect(calls.some(([op]) => op === "cmux.changelog.install")).toBe(false);
  expect(row("2").querySelector("button")?.textContent).toBe("Restart into it");
  await act(async () => row("2").querySelector("button")!.click());
  expect(calls.filter(([op]) => op === "cmux.changelog.install")).toEqual([["cmux.changelog.install", { build: "2" }]]);
  act(() => root.unmount());
});

test("a refusal stays under its build", async () => {
  const { store } = host("That build was pulled from the feed. Pick another one.");
  await store.start();
  await store.firstScreen();
  const { root, row } = await mount(store);
  act(() => row("2").querySelector("button")!.click());
  await act(async () => row("2").querySelector("button")!.click());
  expect(row("2").textContent).toContain("That build was pulled from the feed.");
  expect(store.getSnapshot().installing).toBeUndefined();
  act(() => root.unmount());
});
