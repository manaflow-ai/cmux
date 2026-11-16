// A snapshot the client hands the pane in a frame callback is on screen in that frame (frameCommit.ts, CMUX-571):
// the state it sets is committed before the callback returns, not in a scheduler task after the frame paints.
import { afterEach, expect, test } from "bun:test";
import { act, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { commitInFrame } from "./frameCommit";
import { settleReact } from "../../../test/support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const frames: FrameRequestCallback[] = [];

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of [
    "window",
    "document",
    "navigator",
    "Node",
    "HTMLElement",
    "Element",
    "requestAnimationFrame",
    "IS_REACT_ACT_ENVIRONMENT",
  ])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    // The display frames, run by the test.
    requestAnimationFrame: (callback: FrameRequestCallback) => frames.push(callback),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  scope.IS_REACT_ACT_ENVIRONMENT = true;
  if (root) await act(async () => root!.unmount());
  root = undefined;
  await settleReact();
  dom?.window.close();
  dom = undefined;
  frames.length = 0;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

test("a snapshot set in a frame callback is committed before that frame paints", async () => {
  const container = installDom();
  let setRows: (rows: number) => void = () => {};
  function Pane() {
    const [rows, set] = useState(0);
    setRows = set;
    return <span>{rows} rows</span>;
  }
  root = createRoot(container);
  await act(async () => root!.render(<Pane />));
  expect(container.textContent).toBe("0 rows");

  // The client's emit, as the pane's listener receives it: outside act, as in the page.
  scope.IS_REACT_ACT_ENVIRONMENT = false;
  const cancel = commitInFrame(() => setRows(1));
  expect(frames.length).toBe(1);
  frames.shift()!(16);
  // The frame renders now: the record must already be in the DOM it paints.
  expect(container.textContent).toBe("1 rows");
  cancel();
});
