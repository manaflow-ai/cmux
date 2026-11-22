import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { PageClient } from "../src/pages/shared/pageClient";
import type { UpdateHighlights } from "../src/pages/changelog/updateHighlights";
import { settleReact } from "./support/domTeardown";

// Leo 2026-11-04: "i feel like the restarted after nightly update does too many layout shifts/flicker
// renderings". The sidebar lays the Updated card out at the first height its page reports, so the page
// must not report the host's items and then the span's summary at two heights.
// Leo 2026-11-09: "it should have the updated to Nightly already loaded in, instead of just having a
// blank glass bit ... should have a loading indicator, like an ellipsis-type thing". The host draws the
// card only from its page's first report, and the page reports as soon as it has its data: the title is
// final then, and the change line holds its one line with a quiet indicator until the notes come, so the
// words swap in once, at the same height, with no second report.
test("the Updated card reports with its title and a loading change line, then swaps the words in once", async () => {
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
    // The host draws the card's page only once it reports: the report must not wait for a frame.
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
      // The span's notes: nothing kept on disk, and the network's build list answers when the test
      // says so (a slow first load).
      if (op === "cmux.changelog.list" && (params as { cached?: boolean } | undefined)?.cached === true)
        return Promise.resolve({ builds: [], current: "1.0.0-nightly.42" });
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
    // First render, the notes still loading: the title is there, the change line is a loading line in
    // the note's own box with no words yet, and the page has reported (the host draws the card now).
    expect(host.querySelector(".wn-card-title")?.textContent).toContain("Updated to Nightly");
    const loading = host.querySelector(".wn-card-note-loading");
    expect(loading).not.toBeNull();
    expect(loading?.classList.contains("wn-card-note")).toBe(true);
    expect(loading?.querySelector(".wn-note-label")?.textContent).toBe("Loading what's new");
    expect(host.querySelector(".wn-card-note")?.textContent?.toLowerCase()).not.toContain("readable transcript");
    expect(sizes.length).toBe(1);

    // The list answers with no builds: the host's items are the card's final words. They take the
    // line's place, and the card's height is unchanged, so the page reports nothing new.
    await act(async () => {
      answerList?.({ builds: [], current: "1.0.0-nightly.42" });
      await until(() => host.querySelector(".wn-card-note-loading") === null);
      for (let i = 0; i < 10; i++) await new Promise((resolve) => setTimeout(resolve, 0));
    });
    expect(host.querySelector(".wn-card-note-loading")).toBeNull();
    expect(host.querySelector(".wn-card-note")?.textContent?.toLowerCase()).toContain("readable transcript");
    expect(host.querySelector(".wn-card-title")?.textContent).toContain("Updated to Nightly");
    expect(sizes.length).toBe(1);
  } finally {
    await settleReact();
    dom.window.close();
    for (const [key, had, value] of saved) {
      if (had) scope[key] = value;
      else delete scope[key];
    }
  }
});
