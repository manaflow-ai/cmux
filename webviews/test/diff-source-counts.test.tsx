// The source chip's counts ("Branch +13 -2"): an empty diff, or one that failed to load, showed
// "+0 -0" beside the source (diff viewer before shots, 2026-11-20). With no changed line the chip
// shows no counts; while the diff loads it keeps their place, invisible.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { teardownDom } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "customElements",
  "Node",
  "Element",
  "getComputedStyle",
  "localStorage",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>", { url: "http://localhost/" });
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    customElements: window.customElements,
    Node: window.Node,
    Element: window.Element,
    getComputedStyle: window.getComputedStyle.bind(window),
    localStorage: window.localStorage,
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = window.document.getElementById("root")!;
});

afterAll(async () => {
  act(() => root?.unmount());
  await teardownDom(saved, { scope });
});

async function renderChip(additions: number | null, deletions: number | null) {
  const { createRoot } = await import("react-dom/client");
  const { SourceMenu } = await import("../src/DiffToolbar");
  const { createDiffViewerLabelResolver } = await import("../src/labels");
  root ??= createRoot(host);
  await act(async () =>
    root!.render(
      <SourceMenu
        additions={additions}
        deletions={deletions}
        label={createDiffViewerLabelResolver(undefined, { language: "en" })}
        model={{ sections: [], selected: null }}
        onSelect={() => {}}
      />,
    ),
  );
  const stats = document.querySelector(".source-pill-stats");
  return { text: stats?.textContent ?? null, hidden: stats?.classList.contains("invisible") ?? null };
}

test("a diff with changed lines shows its counts", async () => {
  expect(await renderChip(13, 2)).toEqual({ text: "+13-2", hidden: false });
});

test("a diff with no changed line shows no counts", async () => {
  expect((await renderChip(0, 0)).text).toBeNull();
});

test("while the diff loads the counts keep their place, invisible", async () => {
  expect((await renderChip(null, null)).hidden).toBe(true);
});
