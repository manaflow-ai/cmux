// The diff viewer's auto layout (Codex's diff view does the same): split while the viewer is wide
// enough for two readable sides, unified below that (cx-7tsus: split in a narrow pane wrapped or
// clipped every line), and it changes as the pane is resized. An explicit split stays split in a
// narrow pane. The layout button goes auto, split, unified (Settings' order) and shows the chosen layout.
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

async function renderPill(viewerWidth: number, layout: "split" | "unified" | "auto") {
  const { createRoot } = await import("react-dom/client");
  const { DiffPill } = await import("../src/diff-viewer/Toolbar");
  const { initialAppState } = await import("../src/diff-viewer/state");
  const { createDiffViewerLabelResolver } = await import("../src/labels");
  const base = initialAppState({ payload: {} }, "loading" as never);
  const state = { ...base, viewerWidth, options: { ...base.options, layout } };
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
        onSetLayout={(next) => layouts.push(next)}
        onSetOption={noop}
        state={state}
      />,
    ),
  );
  return { state, layouts, button: document.getElementById("layout-toggle")! };
}

async function drawnStyle(state: Parameters<typeof import("../src/diff-viewer/state").renderedDiffOptions>[0]) {
  const { renderedDiffOptions } = await import("../src/diff-viewer/state");
  const { codeViewOptions } = await import("../src/pierre-options");
  const { resolveDiffViewerAppearance } = await import("../src/appearance");
  return codeViewOptions(renderedDiffOptions(state), resolveDiffViewerAppearance()).diffStyle;
}

test("auto draws unified in a narrow viewer and split in a wide one", async () => {
  expect(await drawnStyle((await renderPill(520, "auto")).state)).toBe("unified");
  // 900 px still cuts long lines on both sides: split starts at 1000 px.
  expect(await drawnStyle((await renderPill(900, "auto")).state)).toBe("unified");
  expect(await drawnStyle((await renderPill(1000, "auto")).state)).toBe("split");
  expect(await drawnStyle((await renderPill(1200, "auto")).state)).toBe("split");
  // An unmeasured viewer counts as wide.
  expect(await drawnStyle((await renderPill(0, "auto")).state)).toBe("split");
});

test("an explicit layout is drawn at every width", async () => {
  expect(await drawnStyle((await renderPill(520, "split")).state)).toBe("split");
  expect(await drawnStyle((await renderPill(1200, "unified")).state)).toBe("unified");
});

test("the layout button goes auto, split, unified and names the next layout", async () => {
  const auto = await renderPill(1200, "auto");
  expect(auto.button.getAttribute("aria-label")).toBe("Switch to split diff");
  await act(async () => auto.button.click());
  expect(auto.layouts).toEqual(["split"]);

  const split = await renderPill(520, "split");
  expect(split.button.getAttribute("aria-label")).toBe("Switch to unified diff");
  expect(split.button.getAttribute("aria-disabled")).toBeNull();
  await act(async () => split.button.click());
  expect(split.layouts).toEqual(["unified"]);

  const unified = await renderPill(520, "unified");
  expect(unified.button.getAttribute("aria-label")).toBe("Switch to auto layout");
  await act(async () => unified.button.click());
  expect(unified.layouts).toEqual(["auto"]);
});

test("a stored auto layout survives the prefs sanitizer", async () => {
  const { sanitizeViewerPrefs } = await import("../src/viewer-prefs");
  expect(sanitizeViewerPrefs({ layout: "auto" })).toEqual({ layout: "auto" });
  expect(sanitizeViewerPrefs({ layout: "diagonal" })).toEqual({});
});
