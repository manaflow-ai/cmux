// Perceived speed (What's New): the host shows a page once it reports its first frame
// (PagePaintProbe.swift, which waits for `__cmuxPaintAfter`), so the changelog holds that report
// until its first screen is final: the list and the notes of every section in view, never a
// "Loading…" frame or empty sections filling one by one. Far-off days still load lazily, and a
// provider that does not answer cannot hold the page past the gate's limit.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "location",
  "IS_REACT_ACT_ENVIRONMENT",
  "__cmuxPaintAfter",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;

/** Each day section sits 400 px below the one before it (jsdom has no layout); the window is 768 px tall. */
function layOutSections(window: JSDOM["window"]) {
  window.HTMLElement.prototype.getBoundingClientRect = function (this: HTMLElement) {
    const sections = [...window.document.querySelectorAll(".clj-section")];
    const top = Math.max(0, sections.indexOf(this)) * 400;
    return { top, bottom: top + 300, left: 0, right: 800, width: 800, height: 300, x: 0, y: top } as DOMRect;
  };
}

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { url: "cmux-page://cmux.changelog/" });
  // Lazy days load as they near the viewport; this observer never reports, so only the first screen loads.
  Object.assign(dom.window, {
    IntersectionObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
  });
  layOutSections(dom.window);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    location: dom.window.location,
    IntersectionObserver: (dom.window as unknown as Record<string, unknown>).IntersectionObserver,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
});

afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
  delete scope.IntersectionObserver;
});

const days = ["2026-10-09", "2026-10-08", "2026-10-07", "2026-10-06", "2026-10-05", "2026-10-04"];

async function provider(delayMs: number | null) {
  const { MockChangelogProvider } = await import("../src/pages/changelog/mockProvider");
  const notes = days.map((date, i) => ({
    build: String(100 - i),
    shortVersion: `1.0.0-nightly.${100 - i}`,
    date,
    highlights: [],
    summary: [{ group: "new" as const, title: `Change from day ${i}` }],
    changes: [],
  }));
  const mock = new MockChangelogProvider(notes);
  const asked: string[] = [];
  const client = {
    call<R>(op: string, params: unknown): Promise<R> {
      if (op === "cmux.changelog.get") asked.push(String((params as { build: string }).build));
      if (delayMs === null) return new Promise<R>(() => {});
      return new Promise<R>((resolve, reject) =>
        setTimeout(() => mock.call<R>(op, params).then(resolve, reject), delayMs),
      );
    },
    subscribe: () => mock.subscribe(),
    handle: (op: string, handler: never) => mock.handle(op, handler),
  };
  return { client, asked };
}

/** What the probe waits for before its frame: the page's gate, else nothing (it reports the next frame). */
function paintGate(): Promise<unknown> {
  return (scope.__cmuxPaintAfter as Promise<unknown> | undefined) ?? Promise.resolve();
}

test("What's New reports its first frame only once the first screen is final", async () => {
  const { mountChangelogPage } = await import("../src/pages/changelog/main");
  const { client, asked } = await provider(15);
  const root = dom.window.document.createElement("div");
  dom.window.document.body.append(root);
  act(() => {
    mountChangelogPage(root, client as never);
  });
  const gate = paintGate();
  await act(async () => {
    await gate;
  });
  const text = root.textContent ?? "";
  expect(text).not.toContain("Loading…");
  // The four days within the viewport and its margin show their notes, not placeholders.
  for (const i of [0, 1, 2, 3]) expect(text).toContain(`Change from day ${i}`);
  const sections = [...root.querySelectorAll(".clj-section")];
  expect(sections.slice(0, 4).every((s) => !s.querySelector(".clj-placeholder"))).toBe(true);
  // Days far below still wait for the reader to scroll near them.
  expect(sections.slice(4).every((s) => !!s.querySelector(".clj-placeholder"))).toBe(true);
  expect(asked).not.toContain("96");
  expect(asked).not.toContain("95");
});

test("a provider that never answers cannot hold the first frame past the limit", async () => {
  const { mountChangelogPage } = await import("../src/pages/changelog/main");
  const { client } = await provider(null);
  const root = dom.window.document.createElement("div");
  dom.window.document.body.append(root);
  act(() => {
    mountChangelogPage(root, client as never);
  });
  const start = performance.now();
  const gate = paintGate();
  await act(async () => {
    await gate;
  });
  expect(performance.now() - start).toBeLessThan(500);
  expect(root.textContent).toContain("Loading…");
});
