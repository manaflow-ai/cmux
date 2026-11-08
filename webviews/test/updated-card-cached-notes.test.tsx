// l10n-allow-file: test fixtures.
import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { PageClient } from "../src/pages/shared/pageClient";
import type { ReleaseNotes } from "../src/pages/changelog/types";
import type { UpdateHighlights } from "../src/pages/changelog/updateHighlights";

// Leo 2026-11-04: "i feel like the restarted after nightly update does too many layout shifts/flicker
// renderings". The relaunch bench at 7ed8d1ffedd: the Updated card's span read the build list from the
// network first (`cmux.changelog.list`), which answered about 2.5 s after the relaunch, past the card's
// 1.5 s wait, so the card reported the host's items (64 pt), then the span's notes (77 pt), and the
// sidebar's list moved under it. The list the host verified and kept on disk lists the update's build
// already: the card reads it first and reports once, with its notes, without waiting on the network.
test("the Updated card reports its span's notes from the cached build list without waiting on the network", async () => {
  const dom = new JSDOM("<!doctype html><div id=root></div>", { url: "https://cmux.test/#/surface/updated" });
  const scope = globalThis as Record<string, unknown>;
  const globals = {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    IS_REACT_ACT_ENVIRONMENT: true,
    ResizeObserver: class {
      constructor(private readonly callback: () => void) {}
      observe() {
        this.callback();
      }
      disconnect() {}
      unobserve() {}
    },
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
  const notes: ReleaseNotes = {
    build: "42",
    shortVersion: "1.0.0-nightly.42",
    date: "2026-11-04",
    highlights: [],
    changes: ["cmux NEXT sidebar: a click never drags (#202)"],
    items: [{ title: "cmux NEXT sidebar: a click never drags", pr: 202 }],
  };
  const until = async (done: () => boolean) => {
    for (let i = 0; i < 200 && !done(); i++) await new Promise((resolve) => setTimeout(resolve, 0));
  };
  const sizes: unknown[] = [];
  const lists: unknown[] = [];
  const client = {
    call: (op: string, params: Record<string, unknown> | undefined) => {
      if (op === "cmux.changelog.surface.get") return Promise.resolve(data);
      if (op === "cmux.changelog.surface.size") {
        sizes.push(params);
        return Promise.resolve(null);
      }
      if (op === "cmux.changelog.list") {
        lists.push(params);
        // The verified list on disk answers at once; the network's never does in this test.
        if (params?.cached === true)
          return Promise.resolve({
            current: "1.0.0-nightly.42",
            builds: [{ build: "42", shortVersion: "1.0.0-nightly.42", date: "2026-11-04", highlights: 0 }],
          });
        return new Promise(() => {});
      }
      if (op === "cmux.changelog.get") return Promise.resolve(notes);
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
      await until(() => sizes.length > 0);
    });
    expect(lists[0]).toEqual({ cached: true });
    expect(sizes.length).toBe(1);
    expect((host.textContent ?? "").toLowerCase()).toContain("click never drags");
  } finally {
    dom.window.close();
    for (const [key, had, value] of saved) {
      if (had) scope[key] = value;
      else delete scope[key];
    }
  }
});
