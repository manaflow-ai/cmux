// l10n-allow-file: test fixture machine names, not shipped UI.
//
// The composer's machine chip and Session Info's local-only actions read where a chat runs from the
// same source as Session Info's machine row (chatMachine.ts). A chat on the machine a remote route
// reaches (the page's acpmux is another machine's, origin `remote`) is never this Mac: the chip names
// that machine, and its folders never open in this Mac's Files (Leo, 2026-11-07: "hmm is the session
// info not accurately describing machine provenance?").
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { proseMirrorGlobals } from "../src/agent-session/acpmux/promptFieldTesting";
import { teardownDom } from "./support/domTeardown";

const THIS_MAC = "cosmic-gray";
const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "IS_REACT_ACT_ENVIRONMENT",
  "HTMLElement",
  "HTMLInputElement",
  "Element",
  "Node",
  "MouseEvent",
  "KeyboardEvent",
  "InputEvent",
  "FocusEvent",
  "PointerEvent",
  "Event",
  "CustomEvent",
  "MutationObserver",
  "ResizeObserver",
  "getSelection",
  "addEventListener",
  "removeEventListener",
  "dispatchEvent",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "localStorage",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
  Object.assign(scope, {
    ...proseMirrorGlobals(dom.window as unknown as Window & typeof globalThis),
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    IS_REACT_ACT_ENVIRONMENT: true,
    HTMLElement: dom.window.HTMLElement,
    HTMLInputElement: dom.window.HTMLInputElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    MouseEvent: dom.window.MouseEvent,
    KeyboardEvent: dom.window.KeyboardEvent,
    InputEvent: dom.window.InputEvent,
    FocusEvent: dom.window.FocusEvent,
    PointerEvent: dom.window.MouseEvent,
    Event: dom.window.Event,
    CustomEvent: dom.window.CustomEvent,
    MutationObserver: dom.window.MutationObserver,
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
    localStorage: dom.window.localStorage,
    addEventListener: dom.window.addEventListener.bind(dom.window),
    removeEventListener: dom.window.removeEventListener.bind(dom.window),
    dispatchEvent: dom.window.dispatchEvent.bind(dom.window),
  });
  host = dom.window.document.getElementById("root")!;
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
});

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

/// The composer's location row for a started chat: what its machine chip says.
async function machineChip(origin: "local" | "remote", summary: Record<string, unknown>): Promise<string> {
  const { createRoot } = await import("react-dom/client");
  const { ComposerContext } = await import("../src/agent-session/acpmux/ComposerContext");
  const props = {
    environments: true,
    summary: { sessionId: "s", harness: "claude", cwd: "/home/dev/cmux", ...summary },
    sessions: [],
    peers: [],
    peerKinds: {},
    // An App whose handshake names this Mac only (no `localMachineName` for the route's machine).
    localName: THIS_MAC,
    route: { origin },
    started: true,
  } as unknown as Parameters<typeof ComposerContext>[0];
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <form className="acpmux-composer">
        <ComposerContext {...props} />
      </form>,
    ),
  );
  // A started chat's chip, read only (the composer's Computer: <machine>).
  return host.querySelector<HTMLElement>('[data-kind="computer"] .acpmux-location-label')?.textContent ?? "";
}

test("over a remote route the composer's machine chip names the route's machine, never this Mac", async () => {
  expect(await machineChip("remote", { machine: "far-box" })).toBe("far-box");
  // A chat on this Mac's own acpmux names this Mac.
  act(() => root?.unmount());
  expect(await machineChip("local", { machine: THIS_MAC })).toBe(THIS_MAC);
});

test("only a chat on this Mac's own acpmux opens its folders here", async () => {
  const { chatOnThisMac } = await import("../src/agent-session/acpmux/chatMachine");
  const chat = { machine: "far-box" };
  expect(chatOnThisMac(chat, {}, { origin: "remote" })).toBe(false);
  expect(chatOnThisMac(chat, {}, { origin: "peer" })).toBe(false);
  expect(chatOnThisMac({ peer: "far-box" }, {}, { origin: "local" })).toBe(false);
  expect(chatOnThisMac({ host: "far-box" }, {}, { origin: "local" })).toBe(false);
  expect(chatOnThisMac({ hostKind: "cloud" }, {}, { origin: "local" })).toBe(false);
  expect(chatOnThisMac({ machine: THIS_MAC }, {}, { origin: "local" })).toBe(true);
  expect(chatOnThisMac(undefined, {}, { origin: "local" })).toBe(false);
});
