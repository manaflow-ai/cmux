// The automatic retry line (AutoResumeNotice.tsx): it says the daemon waits to retry, never that a
// turn already resumed (a fixed condition is no notice), and only once the wait has lasted the shared
// bound (afterDelay.ts LINK_DOWN_SAID_MS): a retry that works inside it is never said.
import { afterEach, expect, jest, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { NoticeSlot } from "./NoticeSlot";
import { AutoResumeNotice } from "./AutoResumeNotice";
import { settleReact } from "../../../test/support/domTeardown";
import { labelExposure } from "../../../test/support/labelExposure";
import { LINK_DOWN_SAID_MS, setLinkDownSaidMs } from "./afterDelay";

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
  jest.useRealTimers();
  setLinkDownSaidMs(LINK_DOWN_SAID_MS);
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

async function render(container: HTMLElement, state: Parameters<typeof AutoResumeNotice>[0]["state"]) {
  root ??= createRoot(container);
  await act(async () => {
    root!.render(
      <NoticeSlot>
        <AutoResumeNotice state={state} />
      </NoticeSlot>,
    );
  });
}

test("the retry line shows while the daemon waits to retry, and nothing once the turn resumed", async () => {
  const container = installDom();
  // This test reads the line as it is said; the bound is the next test's.
  setLinkDownSaidMs(0);
  await render(container, { retry: { attempt: 2, of: 4, reason: "transport" }, attempt: 1 });
  expect(container.querySelector('[data-auto-resume="waiting"]')).not.toBeNull();
  // The retry ran and the turn went on: the condition is fixed, so the pane says nothing about it.
  await render(container, { attempt: 2 });
  expect(container.querySelector("[data-auto-resume]")).toBeNull();
  expect(container.textContent).toBe("");
});

const waiting = () => document.querySelector('[data-auto-resume="waiting"]') !== null;

test("a retry wait is unsaid until it lasts the shared bound, and a retry that works inside it never shows", async () => {
  const container = installDom();
  jest.useFakeTimers();
  const wait: Parameters<typeof AutoResumeNotice>[0]["state"] = { retry: { attempt: 1, of: 5, reason: "transport" } };
  const timeline = (healsAt: number) => [
    { at: 0, apply: () => render(container, wait) },
    { at: healsAt, apply: () => render(container, { attempt: 1 }) },
  ];
  // A retry that runs and works in 0.8 s, and one that works in 6 s: nothing on screen.
  expect(await labelExposure("auto-resume.connect-800ms", timeline(800), 2_000, waiting)).toBe(0);
  expect(await labelExposure("auto-resume.reconnect-6s", timeline(6_000), 8_000, waiting)).toBe(0);
  // A wait that lasts 15 s is said once it has lasted the bound, and goes when the retry works.
  const lasting = await labelExposure("auto-resume.lasting-15s", timeline(15_000), 17_000, waiting);
  expect(lasting).toBe(15_000 - LINK_DOWN_SAID_MS);
  expect(container.textContent).toBe("");
});
