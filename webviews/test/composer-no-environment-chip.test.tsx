// cmux#51731: no composer shows an Environment control. The image a new Cloud chat boots is Settings >
// Cloud > Default Image; the composer's Where chip is named Computer ("Computer: Auto"), never
// "Environment: Auto", in every strip layout, run mode and chat state.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { teardownDom } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "IS_REACT_ACT_ENVIRONMENT",
  "HTMLElement",
  "Element",
  "Node",
  "MouseEvent",
  "KeyboardEvent",
  "FocusEvent",
  "PointerEvent",
  "Event",
  "CustomEvent",
  "MutationObserver",
  "ResizeObserver",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "localStorage",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

beforeAll(async () => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    IS_REACT_ACT_ENVIRONMENT: true,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    MouseEvent: dom.window.MouseEvent,
    KeyboardEvent: dom.window.KeyboardEvent,
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
  });
  host = dom.window.document.getElementById("root")!;
  (await import("../src/agent-session/acpmux/native")).setNativeHost(async () => ({}));
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
});

afterAll(async () => {
  (await import("../src/agent-session/acpmux/native")).setNativeHost(undefined);
  await teardownDom(saved, { window: dom.window, scope });
});

const flush = () => act(async () => await new Promise((done) => setTimeout(done, 0)));

async function mount(extra: Record<string, unknown>) {
  const { createRoot } = await import("react-dom/client");
  const { ComposerContext } = await import("../src/agent-session/acpmux/ComposerContext");
  const props = {
    environments: true,
    stripLayout: "where-machine",
    summary: { sessionId: "", harness: "claude", host: "This Mac", hostKind: "local" },
    localName: "studio-mac",
    projectChoices: [{ cwd: "/Users/you/src/cmux", label: "cmux" }],
    onProject: () => undefined,
    onConnect: () => undefined,
    cloudSignedIn: true,
    ...extra,
  } as unknown as Parameters<typeof ComposerContext>[0];
  root ??= createRoot(host);
  await act(async () => root!.render(<ComposerContext {...props} />));
  await flush();
}

const environmentWords = () =>
  [...host.querySelectorAll<HTMLElement>("*")]
    .flatMap((element) => [
      element.childElementCount === 0 ? (element.textContent ?? "") : "",
      element.getAttribute("aria-label") ?? "",
      element.getAttribute("title") ?? "",
    ])
    .filter((words) => /environment/i.test(words));

const modes = {
  thisMac: { runMode: { mode: "persistent", onMode: () => undefined } },
  cloud: { runMode: { mode: "cloud", onMode: () => undefined } },
  auto: { runMode: { mode: "persistent", onMode: () => undefined, auto: { picked: true, onPick: () => undefined } } },
};
const layouts = ["where-machine", "where-machine-always", "cloud-toggle", "combined"] as const;

test("no composer strip names an Environment, in any layout or run mode; the Where chip is Computer", async () => {
  for (const stripLayout of layouts)
    for (const [name, mode] of Object.entries(modes)) {
      await mount({ stripLayout, ...mode });
      expect({ stripLayout, name, words: environmentWords() }).toEqual({ stripLayout, name, words: [] });
      const named = [...host.querySelectorAll<HTMLElement>("[aria-label],[title]")].map(
        (element) => element.getAttribute("aria-label") ?? element.getAttribute("title") ?? "",
      );
      expect(named.some((words) => words.startsWith("Computer"))).toBe(true);
    }
});

test("a started chat on a Cloud machine names no Environment either", async () => {
  await mount({
    started: true,
    onNewChat: () => undefined,
    peers: ["zesty-indigo-lemur"],
    peerKinds: { "zesty-indigo-lemur": "cloud" },
    summary: {
      sessionId: "s-1",
      harness: "claude",
      host: "zesty-indigo-lemur",
      hostKind: "cloud",
      peer: "zesty-indigo-lemur",
      cwd: "/home/cmux/chats/a",
    },
  });
  expect(environmentWords()).toEqual([]);
});
