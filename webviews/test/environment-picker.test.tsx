// The environment picker (preview, Settings > Advanced > Labs `labs.previewFeatures`): the composer
// location row's computer control becomes one searchable list of where a chat runs, as Claude's
// desktop app has it: Local, SSH and Cloud sections, ⌥⌘1–9 on the first nine rows, and New
// environment at the bottom, which opens the host's SSH connect flow; New Cloud Machine ends the
// Cloud section and opens the host's create flow. It defaults to this computer. The machines come
// from acpmux (`_acpmux/status` peers, by URL scheme, and the hosts its chats ran on); with
// previews off the row keeps its plain Computer menu.
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
/// How often the picker asked the host to read the machines again (`onRefreshMachines`).
let refreshes = 0;

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

// The same reply after the app's relay filters it (AcpmuxPaneMethods.replyShapes): only each
// peer's name and the scheme of its URL reach the page.
const relayedStatus = {
  peers: [
    { name: "gpu-box", transport: "ssh", connected: true },
    { name: "cloud-1", transport: "wss", connected: false },
  ],
};

async function mount(environments: boolean, extra: Record<string, unknown> = {}) {
  const { createRoot } = await import("react-dom/client");
  const { ComposerContext } = await import("../src/agent-session/acpmux/ComposerContext");
  const { peerKindsFromStatus, peerConnectedFromStatus } = await import("../src/agent-session/acpmux/environments");
  const calls: unknown[][] = [];
  refreshes = 0;
  const props = {
    environments,
    summary: { sessionId: "", harness: "claude", host: "This Mac", hostKind: "local" },
    sessions: [
      { sessionId: "a", cwd: "/home/dev/model", host: "gpu-box", peer: "gpu-box", updatedAt: 0 },
      { sessionId: "b", cwd: "/home/you/cache", host: "build-cloud", hostKind: "cloud", updatedAt: 0 },
    ],
    peers: status.peers.map((peer) => peer.name),
    peerKinds: peerKindsFromStatus(relayedStatus),
    peerConnected: peerConnectedFromStatus(relayedStatus),
    onRefreshMachines: () => refreshes++,
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

// Typing as a person does: Base UI auto-highlights only on an input event with an `inputType`.
async function typeKeys(text: string) {
  const field = doc().querySelector<HTMLInputElement>(".acpmux-env-popover input")!;
  const setValue = Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, "value")!.set!;
  for (const data of text) {
    await act(async () => {
      setValue.call(field, field.value + data);
      field.dispatchEvent(new dom.window.InputEvent("input", { bubbles: true, inputType: "insertText", data }));
    });
  }
  return field;
}

async function press(target: Element, init: KeyboardEventInit) {
  await act(async () => {
    target.dispatchEvent(new dom.window.KeyboardEvent("keydown", { bubbles: true, cancelable: true, ...init }));
  });
}

test("a peer's transport reads the same from the relayed reply and the daemon's own", async () => {
  const { peerKindsFromStatus } = await import("../src/agent-session/acpmux/environments");
  const kinds: Record<string, "ssh" | "cloud"> = { "gpu-box": "ssh", "cloud-1": "cloud" };
  expect(peerKindsFromStatus(relayedStatus)).toEqual(kinds);
  expect(peerKindsFromStatus(status)).toEqual(kinds);
  expect(peerKindsFromStatus({ peers: [{ name: "bare" }] })).toEqual({ bare: "cloud" });
});

test("a peer's connected flag reads the same from the relayed reply and the daemon's own", async () => {
  const { peerConnectedFromStatus } = await import("../src/agent-session/acpmux/environments");
  const connected = { "gpu-box": true, "cloud-1": false };
  expect(peerConnectedFromStatus(relayedStatus)).toEqual(connected);
  expect(
    peerConnectedFromStatus({ peers: [...status.peers.slice(0, 1), { ...status.peers[1], connected: false }] }),
  ).toEqual(connected);
  // An older acpmux or relay that sends no flag (or not a boolean) says nothing about the machine.
  expect(peerConnectedFromStatus({ peers: [{ name: "bare" }, { name: "odd", connected: 1 }] })).toEqual({});
});

test("each remote machine shows whether it is connected, read again as the list opens; this Mac shows none", async () => {
  await mount(true);
  expect(refreshes).toBe(0);
  await openPicker();
  expect(refreshes).toBe(1);
  const states = machineRows().map((row) => {
    const mark = row.querySelector(".acpmux-env-status");
    return mark ? [mark.getAttribute("data-connected"), mark.textContent] : null;
  });
  expect(states).toEqual([
    null,
    ["true", t("composer.envConnected")],
    ["false", t("composer.envNotConnected")],
    // A Cloud chat's host acpmux does not list: nothing is known, so nothing is claimed.
    null,
  ]);
});

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
  // New Cloud Machine and Open Cloud… close the Cloud section, the first with what one
  // gives; New environment, last, holds SSH….
  expect(rows().slice(-3)).toEqual(newRows());
  expect(newRows().map((row) => row.querySelector(".acpmux-menu-label")?.textContent)).toEqual([
    t("composer.newCloudMachine"),
    t("composer.openCloud"),
    t("composer.connectSSH"),
  ]);
  expect(newRows()[0]!.querySelector(".acpmux-env-detail")?.textContent).toBe(t("composer.newCloudMachineDetail"));
  expect(newRows().map((row) => row.querySelector(".acpmux-env-row")!.getAttribute("data-section"))).toEqual([
    null,
    null,
    t("composer.newEnvironment"),
  ]);
});

test("with no cloud machine yet, New Cloud Machine heads its own Cloud section and opens the create flow", async () => {
  const calls = await mount(true, {
    sessions: [{ sessionId: "a", cwd: "/home/dev/model", host: "gpu-box", peer: "gpu-box", updatedAt: 0 }],
    peers: ["gpu-box"],
    peerKinds: { "gpu-box": "ssh" },
  });
  await openPicker();
  expect(machineRows().some((row) => row.querySelector('.acpmux-env-row[data-kind="cloud"]'))).toBe(false);
  const cloud = newRows()[0]!;
  expect(cloud.querySelector(".acpmux-env-row")!.getAttribute("data-section")).toBe(t("composer.cloud"));
  // Open Cloud… stays in that one Cloud section.
  expect(newRows()[1]!.querySelector(".acpmux-env-row")!.getAttribute("data-section")).toBeNull();
  await act(async () => cloud.click());
  expect(calls).toEqual([["connect", "cloud"]]);
});

test("the search field filters by name and section, keeping each machine's shortcut", async () => {
  await mount(true);
  await openPicker();
  await type("cloud");
  const shown = machineRows();
  expect(shown.map((row) => rowText(row))).toEqual([`cloud-1${t("composer.envNotConnected")}⌥⌘3`, "build-cloud⌥⌘4"]);
  expect(newRows()).toHaveLength(3);
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

test("New Cloud Machine, Open Cloud… and SSH… open the host's create flow, the Cloud page and the connect flow", async () => {
  const calls = await mount(true);
  for (const index of [0, 1, 2]) {
    await openPicker();
    await act(async () => newRows()[index]!.click());
    expect(doc().querySelector(".acpmux-env-popover")).toBeNull();
  }
  expect(calls).toEqual([
    ["connect", "cloud"],
    ["connect", "cloudPage"],
    ["connect", "ssh"],
  ]);
});

test("each connect choice runs its own host action", async () => {
  const { CONNECT_ACTIONS } = await import("../src/agent-session/acpmux/environments");
  // Open Cloud… opens the Cloud page, whose Sizes and Plans view lists the plan's sizes.
  expect(CONNECT_ACTIONS).toEqual({
    ssh: "remote.connect",
    cloud: "newCloudMachine",
    cloudPage: "palette.openCloudPane",
    move: "cloudMove",
    bringBack: "cloudBringBack",
  });
});

// A started chat's computer is fixed, so its picker lists no other machine to pick: it shows where
// the chat runs and the one move that chat can make, the same action as the tab's right-click menu.
// Which move applies is the app's call (`pane.tabState` `moves`, from that menu), never the page's.
const startedOn = (hostKind: "local" | "cloud" | "ssh") => ({
  started: true,
  onProject: undefined,
  onOffload: undefined as unknown,
  offloads: (hostKind === "local" ? ["move"] : hostKind === "cloud" ? ["bringBack"] : []) as unknown,
  summary:
    hostKind === "local"
      ? { sessionId: "s", harness: "claude", host: "This Mac", hostKind: "local", cwd: "/Users/you/src/cmux" }
      : hostKind === "cloud"
        ? { sessionId: "s", harness: "claude", host: "build-cloud", hostKind: "cloud", cwd: "/home/you/cache" }
        : {
            sessionId: "s",
            harness: "claude",
            host: "gpu-box",
            peer: "gpu-box",
            hostKind: "remote",
            cwd: "/home/dev/model",
          },
});

async function mountStarted(hostKind: "local" | "cloud" | "ssh", offload = true, offloads?: string[]) {
  const calls: unknown[][] = [];
  const extra = startedOn(hostKind);
  if (offloads) extra.offloads = offloads;
  if (offload) extra.onOffload = (kind: string) => calls.push(["offload", kind]);
  const mounted = await mount(true, extra);
  return { calls, mounted };
}

test("a started chat on this Mac: the picker shows this Mac and Move to Cloud, which runs the move", async () => {
  const { calls, mounted } = await mountStarted("local");
  await openPicker();
  expect(machineRows().map(rowText)).toEqual([expect.stringContaining("cosmic-gray")]);
  expect(newRows().map((row) => row.querySelector(".acpmux-menu-label")?.textContent)).toEqual([
    t("composer.moveToCloud"),
  ]);
  expect(newRows()[0]!.querySelector(".acpmux-env-detail")?.textContent).toBe(t("composer.moveToCloudDetail"));
  await act(async () => newRows()[0]!.click());
  expect(doc().querySelector(".acpmux-env-popover")).toBeNull();
  expect(calls).toEqual([["offload", "move"]]);
  expect(mounted).toEqual([]);
});

test("a started Cloud chat: the picker shows its machine and Bring Back Local", async () => {
  const { calls } = await mountStarted("cloud");
  await openPicker();
  expect(machineRows().map(rowText)).toEqual([expect.stringContaining("build-cloud")]);
  expect(newRows().map((row) => row.querySelector(".acpmux-menu-label")?.textContent)).toEqual([
    t("composer.bringBackLocal"),
  ]);
  await act(async () => newRows()[0]!.click());
  expect(calls).toEqual([["offload", "bringBack"]]);
});

test("Return on a search never moves a chat by itself", async () => {
  const { calls } = await mountStarted("local");
  await openPicker();
  await press(await typeKeys("cloud"), { key: "Enter" });
  expect(calls).toEqual([]);
});

test("a started chat with no move to offer keeps the fixed computer label", async () => {
  const fixed = () =>
    [...host.querySelectorAll(".acpmux-location-readonly")].some((label) =>
      (label.getAttribute("aria-label") ?? "").startsWith(t("composer.computer") + ":"),
    );
  // An SSH machine's chat has no move; the floating chat offers none (the host passes no onOffload);
  // a Cloud chat that no move from this Mac put there, or a chat the app won't move, gets none
  // from the app, whatever its machine's kind.
  const cases: [hostKind: "local" | "cloud" | "ssh", offload: boolean, offloads?: string[]][] = [
    ["ssh", true],
    ["local", false],
    ["cloud", true, []],
    ["local", true, []],
  ];
  for (const [hostKind, offload, offloads] of cases) {
    await mountStarted(hostKind, offload, offloads);
    expect(computerButton()).toBeUndefined();
    expect(fixed()).toBe(true);
    act(() => root?.unmount());
    root = undefined;
  }
});

test("Return on a search runs no action Base UI highlighted by itself, but picks a matching machine", async () => {
  let calls = await mount(true);
  await openPicker();
  await press(await typeKeys("gpu"), { key: "Enter" });
  expect(calls).toEqual([["project", "/home/dev/model", "gpu-box"]]);
  act(() => root?.unmount());
  calls = await mount(true);
  await openPicker();
  // "gpu" shows gpu-box; the "z" leaves only New Cloud Machine and SSH…, and Base UI moves its
  // highlight onto New Cloud Machine.
  const field = await typeKeys("gpuz");
  await press(field, { key: "Enter" });
  expect(calls).toEqual([]);
  await press(field, { key: "ArrowDown" });
  await press(field, { key: "ArrowUp" });
  await press(field, { key: "Enter" });
  expect(calls).toEqual([["connect", "cloud"]]);
});

test("choosing the environment already chosen hands focus back to the prompt", async () => {
  const calls = await mount(true);
  await openPicker();
  await act(async () => machineRows()[0]!.click());
  expect(calls).toEqual([]);
  expect(doc().querySelector(".acpmux-env-popover")).toBeNull();
  expect(doc().activeElement).toBe(host.querySelector("textarea"));
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

test("New Tab, previews on: a slower worktree reply doesn't replace a newer choice", async () => {
  const replies: ((folder: string) => void)[] = [];
  await mountNewTab(() => new Promise<string | undefined>((resolve) => replies.push(resolve)));
  await act(async () => worktreeButton()!.click());
  await act(async () => worktreeButton()!.click());
  await act(async () => replies[1]!("/Users/you/wt/app-blue-fox"));
  await act(async () => replies[0]!("/Users/you/wt/app-red-owl"));
  expect(folderName()).toContain("fox");
});
