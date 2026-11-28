// The diff viewer in a narrow pane (cx-7tsus, dogfood run hq #1893): split gave each side about a
// third of the pane, so every line wrapped or clipped. Below the width two readable sides need, the
// viewer draws unified, as GitHub does, and the layout button says why instead of toggling a
// setting that has no effect. The stored preference is kept, so a wider pane draws split again.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

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

afterAll(() => {
  act(() => root?.unmount());
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

async function renderPill(viewerWidth: number) {
  const { createRoot } = await import("react-dom/client");
  const { DiffPill } = await import("../src/diff-viewer/Toolbar");
  const { initialAppState } = await import("../src/diff-viewer/state");
  const { createDiffViewerLabelResolver } = await import("../src/labels");
  const base = initialAppState({ payload: {} }, "loading" as never);
  const state = { ...base, viewerWidth, options: { ...base.options, layout: "split" as const } };
  const layouts: string[] = [];
  const noop = () => {};
  act(() => root?.unmount());
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <DiffPill
        dispatch={noop}
        externalURL={null}
        label={createDiffViewerLabelResolver(undefined, { language: "en" })}
        onCopyGitApply={noop}
        onReload={noop}
        onSetLayout={(layout) => layouts.push(layout)}
        onSetOption={noop}
        state={state}
      />,
    ),
  );
  return { state, layouts, button: document.getElementById("layout-toggle")! };
}

test("a narrow viewer draws a split preference as unified and says so on the layout button", async () => {
  const { renderedDiffOptions } = await import("../src/diff-viewer/state");
  const { codeViewOptions } = await import("../src/pierre-options");
  const { resolveDiffViewerAppearance } = await import("../src/appearance");
  const appearance = resolveDiffViewerAppearance();
  const narrow = await renderPill(520);
  expect(codeViewOptions(renderedDiffOptions(narrow.state), appearance).diffStyle).toBe("unified");
  expect(narrow.button.getAttribute("aria-label")).toBe("Split diff needs a wider pane");
  expect(narrow.button.getAttribute("aria-disabled")).toBe("true");
  await act(async () => narrow.button.click());
  expect(narrow.layouts).toEqual([]);

  const wide = await renderPill(1200);
  expect(codeViewOptions(renderedDiffOptions(wide.state), appearance).diffStyle).toBe("split");
  expect(wide.button.getAttribute("aria-label")).toBe("Switch to unified diff");
  expect(wide.button.getAttribute("aria-disabled")).toBeNull();
});
