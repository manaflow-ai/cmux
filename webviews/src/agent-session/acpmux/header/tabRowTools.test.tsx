// Leo, 2026-11-07 (Trace-ID ask-11b77f340e): a chat's tools dropped into a second row and jumped back up into the
// tab row when a tab was opened, closed or selected. The page reported 0 and then its width each time the App offered
// the row anew, and the App laid the chat under its tabs for the 0. A row offered anew reports the width with no 0.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { useTabRowTools, type TabRow } from "./tabRow";
import { settleReact } from "../../../../test/support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of [
    "window",
    "document",
    "navigator",
    "Node",
    "HTMLElement",
    "Element",
    "ResizeObserver",
    "IS_REACT_ACT_ENVIRONMENT",
  ])
    saved.set(key, scope[key]);
  class StillObserver {
    observe() {}
    disconnect() {}
  }
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    ResizeObserver: StillObserver,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

const reports: number[] = [];
const report = (width: number) => void reports.push(width);

function Tools({ row }: { row: TabRow | undefined }) {
  return <div ref={useTabRowTools(row, report)} />;
}

test("a row offered anew reports the tools' width again with no 0 between; the row's end reports 0", async () => {
  reports.length = 0;
  const container = installDom();
  dom!.window.HTMLElement.prototype.getBoundingClientRect = () => ({ width: 120 }) as DOMRect;
  root = createRoot(container);
  await act(async () => root!.render(<Tools row={{ height: 36, trailingInset: 8 }} />));
  expect(reports).toEqual([124]);
  // A tab opened, closed or selected changed the pane's toolbar: the same row at another inset.
  await act(async () => root!.render(<Tools row={{ height: 36, trailingInset: 40 }} />));
  await act(async () => root!.render(<Tools row={{ height: 36, trailingInset: 8 }} />));
  expect(reports).toEqual([124, 124, 124]);
  // The row ends: the tabs take it back.
  await act(async () => root!.render(<Tools row={undefined} />));
  expect(reports).toEqual([124, 124, 124, 0]);
});
