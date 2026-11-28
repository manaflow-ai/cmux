// The diff viewer's Options menu (dogfood run, hq #1893): with line numbers and backgrounds shown,
// it listed "Hide line numbers" and "Hide backgrounds" with checkmarks, which read as already
// hidden. A checked row now names what is on, as "Hide viewed files" does: Show line numbers ✓.
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

test("a checked view option names what is shown", async () => {
  const { createRoot } = await import("react-dom/client");
  const { DiffPill } = await import("../src/diff-viewer/Toolbar");
  const { initialAppState } = await import("../src/diff-viewer/state");
  const { createDiffViewerLabelResolver } = await import("../src/labels");
  const base = initialAppState({ payload: {} }, "loading" as never);
  const state = {
    ...base,
    optionsOpen: true,
    options: { ...base.options, lineNumbers: true, showBackgrounds: true },
  };
  const noop = () => {};
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <DiffPill
        dispatch={noop}
        externalURL={null}
        label={createDiffViewerLabelResolver(undefined, { language: "en" })}
        onCopyGitApply={noop}
        onReload={noop}
        onSetLayout={noop}
        onSetOption={noop}
        state={state}
      />,
    ),
  );
  const checked = [...document.querySelectorAll('[role="menuitemcheckbox"][aria-checked="true"]')].map(
    (row) => row.querySelector(".menu-label")?.textContent,
  );
  expect(checked).toContain("Show line numbers");
  expect(checked).toContain("Show backgrounds");
  expect(checked.filter((name) => name?.startsWith("Hide"))).toEqual([]);
});
