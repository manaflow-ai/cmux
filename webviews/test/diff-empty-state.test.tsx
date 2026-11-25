// The empty diff says "No changes" on one line (a1315's cuts, 2026-11-20: "No explanatory empty
// state; 'No changes' one line"). It drew a 56 px document tile above the words; an error and the
// loading message never had one.
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

async function renderStatus(status: { message: string; statusOnly?: boolean; error?: boolean }) {
  const { createRoot } = await import("react-dom/client");
  const { LoadingLayer } = await import("../src/diff-viewer/Loading");
  const { createDiffViewerStatus } = await import("../src/status");
  const { createDiffViewerLabelResolver } = await import("../src/labels");
  root ??= createRoot(host);
  await act(async () =>
    root!.render(
      <LoadingLayer
        label={createDiffViewerLabelResolver(undefined, { language: "en" })}
        status={createDiffViewerStatus(status.message, { ...status, loading: false })}
      />,
    ),
  );
  const shown = document.querySelector("#status");
  return { text: shown?.textContent ?? null, children: shown?.children.length ?? 0 };
}

test("an empty diff is one line of text, with no icon", async () => {
  expect(await renderStatus({ message: "No changes", statusOnly: true })).toEqual({
    text: "No changes",
    children: 1,
  });
});

test("an error is one line of text", async () => {
  expect(await renderStatus({ message: "Could not show this diff.", statusOnly: true, error: true })).toEqual({
    text: "Could not show this diff.",
    children: 1,
  });
});
