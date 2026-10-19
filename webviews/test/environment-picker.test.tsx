// The environment picker (preview, Settings > Advanced > Labs `labs.previewFeatures`): the composer
// location row's computer control becomes one searchable list of where a chat runs, as Claude's
// desktop app has it: Local, SSH and Cloud sections, ⌥⌘1–9 on the first nine rows, and New
// environment at the bottom, which opens the host's SSH and cmux Cloud connect flows. It defaults
// to this computer. The machines come from acpmux (`_acpmux/status` peers, by URL scheme, and the
// hosts its chats ran on); with previews off the row keeps its plain Computer menu.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { translate as t } from "../src/agent-session/acpmux/i18n";

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

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
  Object.assign(scope, {
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
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
});

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

// What `_acpmux/status` reports (cmux-tui/crates/acpmux/src/peer.rs Peer::summary): an `ssh://`
// peer and a `wss://` one.
const status = {
  peers: [
    { name: "gpu-box", url: "ssh://dev@gpu-box", connected: true },
    { name: "cloud-1", url: "wss://cloud-1.cmux.dev/acp", connected: true },
  ],
};

async function mount(environments: boolean) {
  const { createRoot } = await import("react-dom/client");
  const { ComposerContext } = await import("../src/agent-session/acpmux/ComposerContext");
  const { peerKindsFromStatus } = await import("../src/agent-session/acpmux/environments");
  const calls: unknown[][] = [];
  const props = {
    environments,
    summary: { sessionId: "", harness: "claude", host: "This Mac", hostKind: "local" },
    sessions: [
      { sessionId: "a", cwd: "/home/dev/model", host: "gpu-box", peer: "gpu-box", updatedAt: 0 },
      { sessionId: "b", cwd: "/home/you/cache", host: "build-cloud", hostKind: "cloud", updatedAt: 0 },
    ],
    peers: status.peers.map((peer) => peer.name),
    peerKinds: peerKindsFromStatus(status),
    localName: "cosmic-gray",
    projectChoices: [{ cwd: "/Users/you/src/cmux", label: "cmux" }],
    onProject: (cwd: string, peer?: string) => calls.push(["project", cwd, peer]),
    onConnect: (kind: string) => calls.push(["connect", kind]),
  } as unknown as Parameters<typeof ComposerContext>[0];
  root = createRoot(host);
  // The composer this row heads: ⌥⌘1–9 work while its field has focus.
  await act(async () =>
    root!.render(
      <form className="acpmux-composer">
        <ComposerContext {...props} />
        <textarea aria-label="Prompt" />
      </form>,
    ),
  );
  return calls;
}

const doc = () => dom.window.document;
const computerButton = () =>
  [...host.querySelectorAll<HTMLButtonElement>(".acpmux-location-button")].find((button) =>
    [t("composer.environment"), t("composer.computer")].some((name) =>
      (button.getAttribute("aria-label") ?? "").startsWith(name + ":"),
    ),
  );
const rows = () => [...doc().querySelectorAll<HTMLElement>(".acpmux-env-popover .acpmux-menu-item")];
const rowText = (row: HTMLElement) => row.textContent?.replace(/\s+/g, " ").trim() ?? "";

async function openPicker() {
  const button = computerButton();
  expect(button, "no computer control").toBeTruthy();
  await act(async () => {
    button!.dispatchEvent(new dom.window.MouseEvent("pointerdown", { bubbles: true }));
    button!.click();
  });
}

async function type(text: string) {
  const field = doc().querySelector<HTMLInputElement>(".acpmux-env-popover input");
  expect(field, "no search field").toBeTruthy();
  const setValue = Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, "value")!.set!;
  await act(async () => {
    setValue.call(field, text);
    field!.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
  });
}

async function press(target: Element, init: KeyboardEventInit) {
  await act(async () => {
    target.dispatchEvent(new dom.window.KeyboardEvent("keydown", { bubbles: true, cancelable: true, ...init }));
  });
}

test("previews off: the row keeps its plain Computer menu", async () => {
  await mount(false);
  expect(computerButton()?.getAttribute("aria-label")).toBe(`${t("composer.computer")}: cosmic-gray`);
  await openPicker();
  expect(doc().querySelector(".acpmux-env-popover")).toBeNull();
});

test("previews on: one list in Local, SSH and Cloud sections, numbered ⌥⌘1–9, defaulting to this computer", async () => {
  await mount(true);
  expect(computerButton()?.getAttribute("aria-label")).toBe(`${t("composer.environment")}: cosmic-gray`);
  await openPicker();
  const shown = rows().filter((row) => row.querySelector(".acpmux-env-row"));
  expect(shown.map((row) => row.querySelector(".acpmux-menu-label")?.textContent)).toEqual([
    "cosmic-gray",
    "gpu-box",
    "cloud-1",
    "build-cloud",
  ]);
  expect(shown.map((row) => row.querySelector(".acpmux-env-row")!.getAttribute("data-section"))).toEqual([
    t("composer.envLocal"),
    t("composer.envSSH"),
    t("composer.cloud"),
    null,
  ]);
  expect(shown.map((row) => row.querySelector(".acpmux-env-key")?.textContent)).toEqual(["⌥⌘1", "⌥⌘2", "⌥⌘3", "⌥⌘4"]);
  expect(shown.map((row) => row.querySelector(".acpmux-env-row")!.hasAttribute("data-current"))).toEqual([
    true,
    false,
    false,
    false,
  ]);
  expect(rowText(rows().at(-1)!)).toBe(t("composer.newEnvironment"));
});

test("the search field filters by name and section, keeping each machine's shortcut", async () => {
  await mount(true);
  await openPicker();
  await type("cloud");
  const shown = rows().filter((row) => row.querySelector(".acpmux-env-row"));
  expect(shown.map((row) => rowText(row))).toEqual(["cloud-1⌥⌘3", "build-cloud⌥⌘4"]);
  expect(rowText(rows().at(-1)!)).toBe(t("composer.newEnvironment"));
});

test("⌥⌘2 in the composer picks the second environment and its folder there", async () => {
  const calls = await mount(true);
  const prompt = host.querySelector("textarea")!;
  prompt.focus();
  // Option changes `key` on a Mac; the physical digit is `code`.
  await press(prompt, { key: "™", code: "Digit2", altKey: true, metaKey: true });
  expect(calls).toEqual([["project", "/home/dev/model", "gpu-box"]]);
  expect(computerButton()?.getAttribute("aria-label")).toBe(`${t("composer.environment")}: gpu-box`);
});

test("⌥⌘ digits do nothing while focus is outside the composer", async () => {
  const calls = await mount(true);
  await press(doc().body, { key: "™", code: "Digit2", altKey: true, metaKey: true });
  expect(calls).toEqual([]);
});

test("New environment offers the SSH and cmux Cloud connect flows", async () => {
  const calls = await mount(true);
  await openPicker();
  const create = rows().at(-1)!;
  await act(async () => create.click());
  expect(rows().map(rowText)).toEqual([t("composer.connectSSH"), t("composer.connectCloud")]);
  await act(async () => rows()[0]!.click());
  expect(calls).toEqual([["connect", "ssh"]]);
});
