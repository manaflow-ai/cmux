import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { PaneBoundary } from "./PaneBoundary";
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

test("a render failure reloads on its own after the backoff, with no button and nothing said at first", async () => {
  const originalError = console.error;
  console.error = () => undefined;
  try {
    let retries = 0;
    function BrokenPane(): never {
      throw new Error("broken pane");
    }

    const host = mount(
      <PaneBoundary
        onRetry={() => retries++}
        autoRetry={{ firstMs: 5, maxMs: 5, random: () => 1, visible: () => true }}
      >
        <BrokenPane />
      </PaneBoundary>,
    );
    expect(host.querySelector("button")).toBeNull();
    expect(host.querySelector("[data-pane-failed]")?.textContent).toBe("");
    await act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 60));
    });
    expect(retries).toBeGreaterThan(0);
    // The stretch is kept across the reloads, so a pane failing on every load backs off.
    const kept = JSON.parse(window.sessionStorage.getItem("acpmux.paneReloads") ?? "null") as { count: number } | null;
    expect(kept?.count).toBeGreaterThan(0);
  } finally {
    console.error = originalError;
  }
});

test("a failure that has lasted past the deadline says one quiet line", () => {
  const originalError = console.error;
  console.error = () => undefined;
  try {
    function BrokenPane(): never {
      throw new Error("broken pane");
    }
    const host = mount(<main />);
    window.sessionStorage.setItem("acpmux.paneReloads", JSON.stringify({ count: 3, since: Date.now() - 60_000 }));
    act(() =>
      root!.render(
        <PaneBoundary onRetry={() => undefined}>
          <BrokenPane />
        </PaneBoundary>,
      ),
    );
    expect(host.querySelector("button")).toBeNull();
    expect(host.textContent).toBe("Still loading the agent pane…");
  } finally {
    console.error = originalError;
  }
});
