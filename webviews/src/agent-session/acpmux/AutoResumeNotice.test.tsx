// The automatic retry line (AutoResumeNotice.tsx): it says the daemon waits to retry, never that a
// turn already resumed (a fixed condition is no notice).
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { NoticeSlot } from "./NoticeSlot";
import { AutoResumeNotice } from "./AutoResumeNotice";
import { LASTING_MS, setLastingGrace } from "../../ui/lasting";
import { settleReact } from "../../../test/support/domTeardown";

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
    "localStorage",
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
    localStorage: dom.window.localStorage,
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

async function render(container: HTMLElement, state: Parameters<typeof AutoResumeNotice>[0]["state"], inQueue = false) {
  root ??= createRoot(container);
  await act(async () => {
    root!.render(
      <NoticeSlot>
        <AutoResumeNotice state={state} inQueue={inQueue} />
      </NoticeSlot>,
    );
  });
}

test("the retry line shows while the daemon waits to retry, and nothing once the turn resumed", async () => {
  const container = installDom();
  // The 10 s bound is the page's (linkDownGrace.test.tsx); here the grace is zero, as in the gallery.
  setLastingGrace(0);
  try {
    await render(container, { retry: { attempt: 2, of: 4, reason: "transport" }, attempt: 1 });
    const line = container.querySelector('.acpmux-queue-status[data-state="retrying"]');
    // Plain words, then the try count: never "Retrying (2/4) after …" (Leo, 2026-11-23: "this looks ass idk").
    expect(line?.textContent).toContain("Connection to the model dropped");
    expect(line?.textContent).toContain("2 of 4");
    // The queue's own status line says it: the slot says nothing, so the state shows once.
    await render(container, { retry: { attempt: 2, of: 4, reason: "transport" }, attempt: 1 }, true);
    expect(container.querySelector(".acpmux-queue-status")).toBeNull();
    // The retry ran and the turn went on: the condition is fixed, so the pane says nothing about it.
    await render(container, { attempt: 2 });
    expect(container.querySelector(".acpmux-queue-status")).toBeNull();
    expect(container.textContent).toBe("");
  } finally {
    setLastingGrace(LASTING_MS);
  }
});
