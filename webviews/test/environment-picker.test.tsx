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
import { noChat } from "../src/gallery/fixtures/acpmux";

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

async function mount(environments: boolean, extra: Record<string, unknown> = {}) {
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
    ...extra,
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
const machineRows = () => rows().filter((row) => row.querySelector(".acpmux-env-row:not(.acpmux-env-new)"));
const newRows = () => rows().filter((row) => row.querySelector(".acpmux-env-new"));
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
  const shown = machineRows();
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
  // New environment, last: SSH… and cmux Cloud… under its heading.
  expect(rows().slice(-2)).toEqual(newRows());
  expect(newRows().map(rowText)).toEqual([t("composer.connectSSH"), t("composer.connectCloud")]);
  expect(newRows()[0]!.querySelector(".acpmux-env-row")!.getAttribute("data-section")).toBe(
    t("composer.newEnvironment"),
  );
});

test("the search field filters by name and section, keeping each machine's shortcut", async () => {
  await mount(true);
  await openPicker();
  await type("cloud");
  const shown = machineRows();
  expect(shown.map((row) => rowText(row))).toEqual(["cloud-1⌥⌘3", "build-cloud⌥⌘4"]);
  expect(newRows()).toHaveLength(2);
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

test("New environment's rows open the SSH and cmux Cloud connect flows", async () => {
  const calls = await mount(true);
  await openPicker();
  await act(async () => newRows()[1]!.click());
  expect(calls).toEqual([["connect", "cloud"]]);
  expect(doc().querySelector(".acpmux-env-popover")).toBeNull();
});

test("⌥⌘1 on the environment already chosen stays the app's", async () => {
  const calls = await mount(true);
  const prompt = host.querySelector("textarea")!;
  prompt.focus();
  const event = new dom.window.KeyboardEvent("keydown", {
    bubbles: true,
    cancelable: true,
    key: "¡",
    code: "Digit1",
    altKey: true,
    metaKey: true,
  });
  await act(async () => {
    prompt.dispatchEvent(event);
  });
  expect(event.defaultPrevented).toBe(false);
  expect(calls).toEqual([]);
});

// hq#2569 #9: a new chat chooses a worktree beside its folder, as Codex's Worktree and Claude's chips do.
const inFolder = {
  summary: { sessionId: "", harness: "claude", host: "This Mac", hostKind: "local", cwd: "/Users/you/src/cmux" },
};
const worktreeButton = () =>
  [...host.querySelectorAll<HTMLButtonElement>(".acpmux-location-button")].find(
    (button) => button.textContent?.trim() === t("worktree.new"),
  );

test("previews on: New Worktree is a control beside the folder, not inside its menu", async () => {
  const worktrees: string[] = [];
  await mount(true, { ...inFolder, onNewWorktree: (cwd: string) => worktrees.push(cwd) });
  const button = worktreeButton();
  expect(button, "no New Worktree beside the folder").toBeTruthy();
  await act(async () => button!.click());
  expect(worktrees).toEqual(["/Users/you/src/cmux"]);
});

test("previews on: no New Worktree on another machine", async () => {
  await mount(true, { ...inFolder, onNewWorktree: () => undefined });
  const prompt = host.querySelector("textarea")!;
  prompt.focus();
  await press(prompt, { key: "™", code: "Digit2", altKey: true, metaKey: true });
  expect(worktreeButton()).toBeUndefined();
});

test("previews off: New Worktree stays in the folder menu only", async () => {
  await mount(false, { ...inFolder, onNewWorktree: () => undefined });
  expect(worktreeButton()).toBeUndefined();
});

async function mountNewTab(onNewWorktree: (cwd: string) => Promise<string | undefined>) {
  const { createRoot } = await import("react-dom/client");
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  const noop = () => {};
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <NewTabScreen
        snapshot={noChat()}
        lastAgent="claude"
        cwd="/Users/you/src/app"
        startCwd="/Users/you/src/app"
        environments
        onConnect={noop}
        onNewWorktree={onNewWorktree}
        onAsk={noop}
        onOpen={noop}
        onSearch={noop}
        onShell={noop}
        onJump={noop}
        onOpenSession={noop}
        onShowAll={noop}
      />,
    ),
  );
}

const folderName = () =>
  host.querySelector<HTMLButtonElement>(`.acpmux-composer-context button[aria-label="${t("composer.folder")}"]`)
    ?.textContent ?? "";

test("New Tab, previews on: New Worktree starts the chat in the worktree the host made", async () => {
  const asked: string[] = [];
  await mountNewTab(async (cwd) => {
    asked.push(cwd);
    return "/Users/you/wt/app-blue-fox";
  });
  expect(folderName()).toBe("app");
  await act(async () => worktreeButton()!.click());
  expect(asked).toEqual(["/Users/you/src/app"]);
  expect(folderName()).toContain("fox");
});

test("New Tab, previews on: the host's refusal shows above the card, and the folder stays", async () => {
  await mountNewTab(async () => {
    throw new Error("not a git repository");
  });
  await act(async () => worktreeButton()!.click());
  expect(host.querySelector('[role="alert"]')?.textContent).toContain("not a git repository");
  expect(folderName()).toBe("app");
});
