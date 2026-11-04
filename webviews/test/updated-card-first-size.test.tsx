import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { PageClient } from "../src/pages/shared/pageClient";
import type { UpdateHighlights } from "../src/pages/changelog/updateHighlights";

// Leo 2026-11-04: "i feel like the restarted after nightly update does too many layout shifts/flicker
// renderings". The sidebar lays the Updated card out at the first height its page reports. The page
// reported the host's items first, then the summary of the update's span once its notes loaded, so the
// sidebar's list moved twice. The card now reports once its words are final.
test("the Updated card reports no height until the notes of its span have loaded", async () => {
  const dom = new JSDOM("<!doctype html><div id=root></div>", { url: "https://cmux.test/#/surface/updated" });
  const scope = globalThis as Record<string, unknown>;
  const observers: (() => void)[] = [];
  const globals = {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    IS_REACT_ACT_ENVIRONMENT: true,
    // Every observed resize answers at once, as WebKit's first layout does.
    ResizeObserver: class {
      constructor(private readonly callback: () => void) {
        observers.push(callback);
      }
      observe() {
        this.callback();
      }
      disconnect() {}
      unobserve() {}
    },
    // The card's page is hidden until it reports (the host shows it once it has a height): it gets no
    // animation frame, so it must report without one.
    requestAnimationFrame: () => 0,
  };
  const saved = Object.keys(globals).map((key) => [key, key in scope, scope[key]] as const);
  Object.assign(scope, globals);
  const data: UpdateHighlights = {
    version: "1.0.0-nightly.42",
    build: "42",
    fromVersion: "1.0.0-nightly.41",
    fromBuild: "41",
    source: "whatsNew",
    language: "en",
    moreCount: 0,
    items: [{ id: "top", title: "Readable transcript", category: "new" }],
    rest: [],
    changelog: { from: "1.0.0-nightly.41", to: "1.0.0-nightly.42" },
  };
  // Yields macrotasks (the notes store waits on `setTimeout(0)`) until `done` holds, at most 200 times.
  const until = async (done: () => boolean) => {
    for (let i = 0; i < 200 && !done(); i++) await new Promise((resolve) => setTimeout(resolve, 0));
  };
  const sizes: unknown[] = [];
  let answerList: ((value: unknown) => void) | undefined;
  const client = {
    call: (op: string, params: unknown) => {
      if (op === "cmux.changelog.surface.get") return Promise.resolve(data);
      if (op === "cmux.changelog.surface.size") {
        sizes.push(params);
        return Promise.resolve(null);
      }
      // The span's notes: the build list answers when the test says so (a slow first load).
      if (op === "cmux.changelog.list") return new Promise((resolve) => (answerList = resolve));
      return Promise.reject(new Error(`unavailable ${op}`));
    },
    subscribe: async () => () => {},
    handle: () => () => {},
  } as unknown as PageClient;
  try {
    const { mountUpdateSurface } = await import("../src/pages/changelog/surface");
    const host = dom.window.document.getElementById("root")!;
    await act(async () => mountUpdateSurface(host, "updated", client));
    await act(async () => {
      await until(() => host.querySelector(".wn-card") !== null);
      for (const observer of observers) observer();
      // Room for a report the page would send now (a few turns after the card drew).
      for (let i = 0; i < 10; i++) await new Promise((resolve) => setTimeout(resolve, 0));
    });
    expect(host.querySelector(".wn-card")).not.toBeNull();
    expect(sizes).toEqual([]);

    // The list answers with no builds: the host's items are the card's final words, and it reports.
    await act(async () => {
      answerList?.({ builds: [], current: "1.0.0-nightly.42" });
      await until(() => sizes.length > 0);
    });
    expect(sizes.length).toBe(1);
  } finally {
    dom.window.close();
    for (const [key, had, value] of saved) {
      if (had) scope[key] = value;
      else delete scope[key];
    }
  }
});
