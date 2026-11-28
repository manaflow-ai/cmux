// The changes view's file list with nothing to show (dogfood run, hq #1893): after a commit left no
// uncommitted changes, it said "No matching files" under an empty filter, as if a search had found
// nothing. With no filter it now says "No changes"; a filter that matches nothing still says no
// files match.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

const scope = globalThis as Record<string, unknown>;
const { window } = new JSDOM("<!doctype html><div id=root></div>", { url: "http://localhost/" });
// The tree is a custom element: it needs the DOM's constructors, not only window and document.
const dom = Object.fromEntries(
  Object.getOwnPropertyNames(window)
    .filter((key) =>
      /^(HTML|SVG|CSS|Mutation|Shadow|Document|Element|Node|Text|Event|Custom|Keyboard|Pointer)/.test(key),
    )
    .map((key) => [key, (window as unknown as Record<string, unknown>)[key]]),
);
const globals: Record<string, unknown> = {
  ...dom,
  window,
  document: window.document,
  navigator: window.navigator,
  customElements: window.customElements,
  getComputedStyle: window.getComputedStyle.bind(window),
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
  cancelAnimationFrame: (id: number) => clearTimeout(id),
  IS_REACT_ACT_ENVIRONMENT: true,
};
const saved = Object.keys(globals).map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  Object.assign(scope, globals);
  host = window.document.getElementById("root")!;
});

afterAll(() => {
  act(() => root?.unmount());
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

test("the changes file list says No changes until a filter matches nothing", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ChangedFilesTree } = await import("../src/agent-session/acpmux/changes/ChangedFilesTree");
  root = createRoot(host);
  await act(async () => root!.render(<ChangedFilesTree files={[]} onSelect={() => {}} />));
  const empty = () => host.querySelector(".acpmux-diff-tree-empty")?.textContent;
  expect(empty()).toBe("No changes");

  const filter = host.querySelector<HTMLInputElement>('input[type="search"]')!;
  await act(async () => {
    filter.value = "payments";
    filter.dispatchEvent(new window.Event("input", { bubbles: true }));
  });
  expect(empty()).toBe("No matching files");
});
