// l10n-allow-file: test fixture machine names, not shipped UI.
//
// The banner over a Cloud chat's kept copy waits before it speaks (Leo, 2026-11-14: connectivity says
// nothing the person can do nothing about). What the app recovers by itself waits LINK_DOWN_SAID_MS
// (10 s): a dropped link ("offline") and a machine the app wakes on its own ("starting" with no Resume
// asked here). A paused machine, which has a Resume, and a start the person asked for keep the short
// RESUME_NOTE_DELAY_MS.
import { afterAll, afterEach, beforeAll, expect, jest, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { teardownDom } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "IS_REACT_ACT_ENVIRONMENT", "HTMLElement", "Element", "Node"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    IS_REACT_ACT_ENVIRONMENT: true,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
  });
  host = dom.window.document.getElementById("root")!;
});

afterEach(async () => {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
  jest.useRealTimers();
});

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

const shown = () => host.querySelector<HTMLElement>(".acpmux-peer-copy-slot")?.dataset.shown === "true";

async function mount(machine: "paused" | "starting" | undefined, extra: { asked?: boolean } = {}) {
  jest.useFakeTimers();
  const { createRoot } = await import("react-dom/client");
  const { PeerCopyBanner } = await import("../src/agent-session/acpmux/PeerCopyBanner");
  root = createRoot(host);
  // `asked` is spread so the test reads the same on a base whose banner has no such prop.
  const props = { copy: { peer: "dev-vm", offline: true }, machine, onResume: () => undefined, ...extra };
  await act(async () => root!.render(<PeerCopyBanner {...props} onReconnect={async () => undefined} />));
}

const advance = async (ms: number) => act(async () => void jest.advanceTimersByTime(ms));
const unmount = () => {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
};

test("an offline Cloud chat's banner stays out of sight for 10 s, then shows", async () => {
  await mount(undefined);
  await advance(1_500);
  expect(shown()).toBe(false);
  await advance(8_499);
  expect(shown()).toBe(false);
  await advance(1);
  expect(shown()).toBe(true);
});

test("a machine the app wakes by itself says nothing for 10 s either", async () => {
  await mount("starting");
  await advance(9_999);
  expect(shown()).toBe(false);
  await advance(1);
  expect(shown()).toBe(true);
});

test("a paused machine, and a start the person asked for, keep the short delay", async () => {
  await mount("paused");
  await advance(1_500);
  expect(shown()).toBe(true);
  unmount();
  await mount("starting", { asked: true });
  await advance(1_500);
  expect(shown()).toBe(true);
});
