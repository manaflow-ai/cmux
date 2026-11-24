import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { PaneBoundary } from "./PaneBoundary";
import { paneFailureLine } from "./paneFailureLine";
import { settleReact } from "../../../test/support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

afterEach(async () => {
  act(() => root?.unmount());
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

function mount(node: React.ReactNode): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
  });
  for (const key of ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  const host = dom.window.document.getElementById("root")!;
  root = createRoot(host);
  act(() => root!.render(node));
  return host;
}

test("retry invokes the caller recovery hook after a render failure", () => {
  const originalError = console.error;
  console.error = () => undefined;
  try {
    let retries = 0;
    function BrokenPane(): never {
      throw new Error("broken pane");
    }

    const host = mount(
      <PaneBoundary onRetry={() => retries++}>
        <BrokenPane />
      </PaneBoundary>,
    );
    const retry = host.querySelector<HTMLButtonElement>(".acpmux-pane-failed__retry")!;
    act(() => retry.click());
    expect(retries).toBe(1);
  } finally {
    console.error = originalError;
  }
});

test("a caught render error is logged with what failed, the error's own words and where", () => {
  const originalError = console.error;
  const logged: unknown[][] = [];
  console.error = (...args: unknown[]) => void logged.push(args);
  try {
    function BrokenPane(): never {
      throw new Error("Maximum update depth exceeded");
    }
    const host = mount(
      <PaneBoundary>
        <BrokenPane />
      </PaneBoundary>,
    );
    expect(host.querySelector(".acpmux-pane-failed")).not.toBeNull();
    const line = logged.find((args) =>
      String(args[0]).startsWith("agent pane render failed: Maximum update depth exceeded"),
    );
    expect(line, JSON.stringify(logged.map((args) => String(args[0])))).toBeDefined();
    // The journal keeps a console error's first line only: where it failed is on that line.
    const first = String(line![0]).split("\n")[0]!;
    expect(first).toContain("in: ");
    expect(first).toContain("PaneBoundary");
    expect(first).toContain("stack: ");
    expect((line![1] as Error).message).toBe("Maximum update depth exceeded");
    // Where: the component stack under the boundary (bun names the throwing function <anonymous>).
    expect(String(line![2])).toContain("at PaneBoundary");
  } finally {
    console.error = originalError;
  }
});

test("a thrown value that is not an Error still says what it was", () => {
  expect(paneFailureLine("bad state")).toBe("agent pane render failed: bad state");
  const empty = new Error("");
  empty.stack = "";
  expect(paneFailureLine(empty)).toBe("agent pane render failed: no message");
});

test("the logged line names components and frames on its one line", () => {
  const error = new Error("Minified React error #185");
  error.stack =
    "Error: Minified React error #185\n    at BU (cmux-page://cmux.agent/pane.js:8:27998)\n    at Kq (cmux-page://cmux.agent/pane.js:8:9001)";
  const line = paneFailureLine(
    error,
    "\n    at Rce (cmux-page://cmux.agent/pane.js:12:345)\n    at PaneBoundary (cmux-page://cmux.agent/pane.js:1:2)",
  );
  expect(line).toBe(
    "agent pane render failed: Minified React error #185 | in: Rce@pane.js:12:345 < PaneBoundary@pane.js:1:2 | stack: BU@pane.js:8:27998, Kq@pane.js:8:9001",
  );
  expect(line).not.toContain("\n");
  // JSC's `name@url` frames read the same way.
  const jsc = new Error("x");
  jsc.stack = "Rce@cmux-page://cmux.agent/pane.js:8:1\n@cmux-page://cmux.agent/pane.js:9:2";
  expect(paneFailureLine(jsc)).toBe("agent pane render failed: x | stack: Rce@pane.js:8:1, pane.js:9:2");
});
