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
  dom = new JSDOM("<!doctype html><div id=root></div>", {
    pretendToBeVisual: true,
    url: "https://cmux.test/",
  });
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
      {
        sessionId: "b",
        cwd: "/home/you/cache",
        host: "build-cloud",
        hostKind: "cloud",
        updatedAt: 0,
      },
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

async function openPicker(init: { altKey?: boolean } = {}) {
  const button = computerButton();
  expect(button, "no computer control").toBeTruthy();
  await act(async () => {
    button!.dispatchEvent(new dom.window.MouseEvent("pointerdown", { bubbles: true, ...init }));
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
    peerConnectedFromStatus({
      peers: [...status.peers.slice(0, 1), { ...status.peers[1], connected: false }],
    }),
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
    const state = row.querySelector(".acpmux-env-state");
    return mark ? [mark.getAttribute("data-connected"), mark.textContent] : state ? ["state", state.textContent] : null;
  });
  expect(states).toEqual([
    null,
    ["true", t("composer.envConnected")],
    // A Cloud chat's host acpmux does not list: nothing is known, so nothing is claimed.
    null,
    // Not connected: greyed, last in its section, saying so, and not a pick.
    ["state", t("composer.envNotConnected")],
  ]);
});

test("previews off: the row keeps its plain Computer menu", async () => {
  await mount(false);
  expect(computerButton()?.getAttribute("aria-label")).toBe(`${t("composer.computer")}: cosmic-gray`);
  await openPicker();
  expect(doc().querySelector(".acpmux-env-popover")).toBeNull();
});

test("previews on: one list in This Mac, My machines and Cloud and VMs sections, numbered ⌥⌘1–9, defaulting to this computer", async () => {
  await mount(true);
  expect(computerButton()?.getAttribute("aria-label")).toBe(`${t("composer.environment")}: cosmic-gray`);
  await openPicker();
  const shown = machineRows();
  expect(shown.map((row) => row.querySelector(".acpmux-menu-label")?.textContent)).toEqual([
    "cosmic-gray",
    "gpu-box",
    "build-cloud",
    "cloud-1",
  ]);
  expect(shown.map((row) => row.querySelector(".acpmux-env-row")!.getAttribute("data-section"))).toEqual([
    t("composer.thisMac"),
    t("composer.envMine"),
    t("composer.envFleet"),
    null,
  ]);
  // The machine that is not connected takes no shortcut.
  expect(shown.map((row) => row.querySelector(".acpmux-env-key")?.textContent)).toEqual([
    "⌥⌘1",
    "⌥⌘2",
    "⌥⌘3",
    undefined,
  ]);
  expect(shown.map((row) => row.querySelector(".acpmux-env-row")!.hasAttribute("data-current"))).toEqual([
    true,
    false,
    false,
    false,
  ]);
  // New Cloud Machine and Open Cloud… close the Cloud section, the first with what one
  // gives; New environment, last, holds SSH…, Connect Phone… and Add Machine… (Add Device),
  // the list's last row.
  expect(rows().slice(-5)).toEqual(newRows());
  expect(newRows().map((row) => row.querySelector(".acpmux-menu-label")?.textContent)).toEqual([
    t("composer.newCloudMachine"),
    t("composer.openCloud"),
    t("composer.connectSSH"),
    t("composer.connectPhone"),
    t("composer.addMachine"),
  ]);
  expect(newRows()[0]!.querySelector(".acpmux-env-detail")?.textContent).toBe(t("composer.newCloudMachineDetail"));
  expect(newRows().map((row) => row.querySelector(".acpmux-env-row")!.getAttribute("data-section"))).toEqual([
    null,
    null,
    t("composer.newEnvironment"),
    null,
    null,
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
  expect(cloud.querySelector(".acpmux-env-row")!.getAttribute("data-section")).toBe(t("composer.envFleet"));
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
  expect(shown.map((row) => rowText(row))).toEqual(["build-cloud⌥⌘3", `cloud-1${t("composer.envNotConnected")}`]);
  // The search narrows the machines; every action row stays.
  expect(newRows()).toHaveLength(5);
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

test("New Cloud Machine, Open Cloud…, SSH…, Connect Phone… and Add Machine… open the host's create flow, the Cloud page, the connect flow, the pairing page and Add Device", async () => {
  const calls = await mount(true);
  for (const index of [0, 1, 2, 3, 4]) {
    await openPicker();
    await act(async () => newRows()[index]!.click());
    expect(doc().querySelector(".acpmux-env-popover")).toBeNull();
  }
  expect(calls).toEqual([
    ["connect", "cloud"],
    ["connect", "cloudPage"],
    ["connect", "ssh"],
    ["connect", "phone"],
    ["connect", "addMachine"],
  ]);
});

test("each connect choice runs its own host action", async () => {
  const { CONNECT_ACTIONS } = await import("../src/agent-session/acpmux/environments");
  // Open Cloud… opens the Cloud page, whose Sizes and Plans view lists the plan's sizes.
  expect(CONNECT_ACTIONS).toEqual({
    ssh: "remote.connect",
    cloud: "newCloudMachine",
    cloudPage: "palette.openCloudPane",
    addMachine: "device.add",
    move: "cloudMove",
    bringBack: "cloudBringBack",
    phone: "palette.mobileConnect",
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
      ? {
          sessionId: "s",
          harness: "claude",
          host: "This Mac",
          hostKind: "local",
          cwd: "/Users/you/src/cmux",
        }
      : hostKind === "cloud"
        ? {
            sessionId: "s",
            harness: "claude",
            host: "build-cloud",
            hostKind: "cloud",
            cwd: "/home/you/cache",
          }
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
  summary: {
    sessionId: "",
    harness: "claude",
    host: "This Mac",
    hostKind: "local",
    cwd: "/Users/you/src/cmux",
  },
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

async function mountNewTab(onNewWorktree: (cwd: string) => Promise<string | undefined>, snapshot = noChat()) {
  const { createRoot } = await import("react-dom/client");
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  const noop = () => {};
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <NewTabScreen
        snapshot={snapshot}
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

test("New Tab, previews on: a worktree reply after a machine pick doesn't take the chat back here", async () => {
  const replies: ((folder: string) => void)[] = [];
  const snapshot = noChat([], {
    peers: ["devbox"],
    peerKinds: { devbox: "ssh" },
    peerConnected: { devbox: true },
  });
  await mountNewTab(() => new Promise<string | undefined>((resolve) => replies.push(resolve)), snapshot);
  await act(async () => worktreeButton()!.click());
  await openPicker();
  const devbox = machineRows().find((row) => row.textContent?.includes("devbox"))!;
  await act(async () => devbox.click());
  await act(async () => replies[0]!("/Users/you/wt/app-red-owl"));
  expect(computerButton()?.getAttribute("aria-label")).toBe(`${t("composer.environment")}: devbox`);
  expect(folderName()).not.toContain("owl");
});

test("without Labs, or once the chat started, there is no Sandboxed", async () => {
  const runMode = { mode: "persistent", onMode: () => undefined };
  await mount(false, { runMode });
  expect(host.textContent).not.toContain(t("composer.sandboxed"));
  act(() => root?.unmount());
  root = undefined;
  await mount(true, { runMode, started: true, onOffload: () => undefined, offloads: ["move"] });
  await openPicker();
  await press(doc().body, { key: "Alt", altKey: true });
  expect(doc().querySelector('.acpmux-env-popover [data-mode="sandboxed"]')).toBeNull();
});

// The daemon's host list (`_acpmux/status` peers as the relay keeps them, sorted by name): four
// machines of the person's own, two numbered VM pools (some still reconnecting) and a Cloud machine.
const pools = [
  ...Array.from({ length: 6 }, (_, index) => ({
    name: `agent-vm-${index + 1}`,
    state: index >= 2 ? (index === 5 ? "degraded" : "reconnecting") : "connected",
  })),
  ...Array.from({ length: 10 }, (_, index) => ({
    name: `ci-vm-${String(index + 1).padStart(2, "0")}`,
    state: "connected",
  })),
];
const daemonHosts = {
  peers: [
    ...[
      ...pools,
      { name: "build-mini-2", state: "connected" },
      { name: "desk-mac", state: "connected" },
      { name: "gpu-box", state: "offline" },
      { name: "home-linux", state: "connected" },
    ].map(({ name, state }) => ({
      name,
      transport: "ssh",
      connected: state !== "reconnecting" && state !== "offline",
      state,
    })),
    { name: "cloud-1", transport: "wss", connected: true, state: "connected" },
  ].sort((a, b) => (a.name < b.name ? -1 : 1)),
};

async function daemonMachines() {
  const environments = await import("../src/agent-session/acpmux/environments");
  const machines = environments.knownMachines(
    daemonHosts.peers.map((peer) => peer.name),
    [],
    environments.peerKindsFromStatus(daemonHosts),
    [],
    environments.peerConnectedFromStatus(daemonHosts),
    environments.peerStatesFromStatus(daemonHosts),
  );
  return { ...environments, machines };
}

test("the daemon's host list maps to sections, connected first, in number order, each with its state", async () => {
  const { machines, orderEnvironments, environmentSections, environmentReady, numberedEnvironments } =
    await daemonMachines();
  expect(machines).toHaveLength(21);
  const sections = environmentSections(machines);
  const ordered = orderEnvironments(machines);
  expect(ordered.map((machine) => [machine.label, sections.get(machine.id), machine.state])).toEqual([
    // The person's own: SSH machines that are no numbered pool (one numbered name alone is not).
    ["build-mini-2", "mine", "connected"],
    ["desk-mac", "mine", "connected"],
    ["home-linux", "mine", "connected"],
    ["gpu-box", "mine", "offline"],
    // Cloud and VMs: the pools by number (2 before 10) and the Cloud machine, then the rest.
    ["agent-vm-1", "fleet", "connected"],
    ["agent-vm-2", "fleet", "connected"],
    ...Array.from({ length: 10 }, (_, index) => [`ci-vm-${String(index + 1).padStart(2, "0")}`, "fleet", "connected"]),
    ["cloud-1", "fleet", "connected"],
    ["agent-vm-3", "fleet", "reconnecting"],
    ["agent-vm-4", "fleet", "reconnecting"],
    ["agent-vm-5", "fleet", "reconnecting"],
    // Connected but still in its handshake: not a place a chat starts yet.
    ["agent-vm-6", "fleet", "degraded"],
  ]);
  expect(ordered.filter((machine) => !environmentReady(machine))).toHaveLength(5);
  const numbered = numberedEnvironments(machines).map((machine) => machine.label);
  expect(numbered.join(" ")).toBe(
    "build-mini-2 desk-mac home-linux agent-vm-1 agent-vm-2 ci-vm-01 ci-vm-02 ci-vm-03 ci-vm-04",
  );
});

test("a peer's link state reads the same from the relayed reply and the daemon's own; an older daemon's none", async () => {
  const { peerStatesFromStatus, environmentReady } = await import("../src/agent-session/acpmux/environments");
  expect(peerStatesFromStatus({ peers: [{ name: "a", url: "ssh://a", state: "reconnecting" }] })).toEqual({
    a: "reconnecting",
  });
  expect(
    peerStatesFromStatus({
      peers: [{ name: "a", transport: "ssh", state: "connected" }, { name: "b" }],
    }),
  ).toEqual({ a: "connected" });
  // No state: the connected flag decides; nothing known counts as a place to start.
  expect(environmentReady({ id: "a", label: "a", kind: "ssh", connected: false })).toBe(false);
  expect(environmentReady({ id: "a", label: "a", kind: "ssh" })).toBe(true);
});

const daemonProps = async (extra: Record<string, unknown> = {}) => {
  const { peerKindsFromStatus, peerConnectedFromStatus, peerStatesFromStatus } =
    await import("../src/agent-session/acpmux/environments");
  const computers: string[] = [];
  return {
    computers,
    props: {
      sessions: [],
      peers: daemonHosts.peers.map((peer) => peer.name),
      peerKinds: peerKindsFromStatus(daemonHosts),
      peerConnected: peerConnectedFromStatus(daemonHosts),
      peerStates: peerStatesFromStatus(daemonHosts),
      onComputer: (computer: string) => computers.push(computer),
      ...extra,
    },
  };
};

test("previews on: every machine the daemon lists, grouped; the ones not connected greyed with their state", async () => {
  const { computers, props } = await daemonProps();
  await mount(true, props);
  await openPicker();
  const shown = machineRows();
  expect(shown).toHaveLength(22);
  const sectionHeads = shown
    .map((row) => row.querySelector(".acpmux-env-row")!.getAttribute("data-section"))
    .filter(Boolean);
  expect(sectionHeads).toEqual([t("composer.thisMac"), t("composer.envMine"), t("composer.envFleet")]);
  const greyed = shown.filter((row) => row.querySelector('.acpmux-env-row[data-ready="false"]'));
  expect(
    greyed.map((row) => [
      row.querySelector(".acpmux-menu-label")?.textContent,
      row.querySelector(".acpmux-env-state")?.textContent,
    ]),
  ).toEqual([
    ["gpu-box", t("composer.envNotConnected")],
    ["agent-vm-3", t("header.reconnecting")],
    ["agent-vm-4", t("header.reconnecting")],
    ["agent-vm-5", t("header.reconnecting")],
    ["agent-vm-6", t("rail.connectorPending")],
  ]);
  // A greyed machine stays in its place, in its section, and is no pick: the list stays open.
  const label = (row: Element) => row.querySelector(".acpmux-menu-label")?.textContent;
  expect(shown.slice(1, 5).map(label).join(" ")).toBe("build-mini-2 desk-mac home-linux gpu-box");
  expect(greyed.every((row) => row.querySelector('[aria-disabled="true"]'))).toBe(true);
  await act(async () => greyed[1]!.click());
  expect(computers).toEqual([]);
  expect(doc().querySelector(".acpmux-env-popover")).not.toBeNull();
  // A connected one is: the new chat moves there.
  const target = shown.find((row) => label(row) === "ci-vm-10")!;
  await act(async () => target.click());
  expect(computers).toEqual(["ci-vm-10"]);
  expect(computerButton()?.getAttribute("aria-label")).toBe(`${t("composer.environment")}: ci-vm-10`);
});

test("previews on: 20+ machines stay searchable by name and section", async () => {
  const { props } = await daemonProps();
  await mount(true, props);
  await openPicker();
  await type("agent 1");
  expect(machineRows().map((row) => row.querySelector(".acpmux-menu-label")?.textContent)).toEqual(["agent-vm-1"]);
  await type("my machines");
  const mine = machineRows().map((row) => row.querySelector(".acpmux-menu-label")?.textContent);
  expect(mine.join(" ")).toBe("build-mini-2 desk-mac home-linux gpu-box");
});

test("previews off: the plain Computer menu lists the same machines, in the same sections, greyed the same way", async () => {
  const { computers, props } = await daemonProps();
  await mount(false, props);
  await openPicker();
  // The machine rows (SSH… and New Cloud Machine follow them as buttons).
  const items = [...doc().querySelectorAll<HTMLElement>(".acpmux-location-menu .acpmux-menu-item")].filter((item) =>
    item.querySelector(".acpmux-location-name"),
  );
  const names = items.map((item) => item.querySelector(".acpmux-menu-label")?.textContent);
  expect(names.slice(0, 5)).toEqual(["cosmic-gray", "build-mini-2", "desk-mac", "home-linux", "gpu-box"]);
  expect(names).toHaveLength(22);
  expect(
    items.map((item) => item.querySelector(".acpmux-location-name")!.getAttribute("data-section")).filter(Boolean),
  ).toEqual([t("composer.thisMac"), t("composer.envMine"), t("composer.envFleet")]);
  const offline = items[4]!;
  expect(offline.querySelector(".acpmux-location-name")!.getAttribute("data-ready")).toBe("false");
  expect(offline.querySelector(".acpmux-menu-description")?.textContent).toBe(t("composer.envNotConnected"));
  await act(async () => offline.click());
  expect(computers).toEqual([]);
  expect(doc().querySelector(".acpmux-location-menu")).not.toBeNull();
  await act(async () => items[2]!.click());
  expect(computers).toEqual(["desk-mac"]);
});

test("an open machine list reads the machines again until it closes", async () => {
  const { MACHINES_REFRESH_MS } = await import("../src/agent-session/acpmux/EnvironmentPicker");
  expect(MACHINES_REFRESH_MS).toBeLessThanOrEqual(5_000);
  const { props } = await daemonProps();
  const realSetInterval = globalThis.setInterval;
  const realClearInterval = globalThis.clearInterval;
  // Only the machine list's own timer (its period) is counted; anything else runs as it would.
  const timers = new Map<unknown, () => void>();
  globalThis.setInterval = ((callback: () => void, ms?: number, ...rest: unknown[]) => {
    const id = realSetInterval(callback, ms, ...rest);
    if (ms === MACHINES_REFRESH_MS) timers.set(id, callback);
    return id;
  }) as unknown as typeof setInterval;
  globalThis.clearInterval = ((id: Parameters<typeof clearInterval>[0]) => {
    timers.delete(id);
    realClearInterval(id);
  }) as unknown as typeof clearInterval;
  try {
    await mount(true, props);
    await openPicker();
    expect(refreshes).toBe(1);
    expect(timers.size).toBe(1);
    await act(async () => {
      for (const tick of timers.values()) tick();
    });
    expect(refreshes).toBe(2);
    await press(doc().querySelector(".acpmux-env-popover input")!, { key: "Escape" });
    expect(doc().querySelector(".acpmux-env-popover")).toBeNull();
    expect(timers.size).toBe(0);
  } finally {
    globalThis.setInterval = realSetInterval;
    globalThis.clearInterval = realClearInterval;
  }
});

test("a numbered pair is the person's own; three or more of one stem are a pool", async () => {
  const { environmentSections } = await import("../src/agent-session/acpmux/environments");
  const ssh = (name: string) => ({
    id: name,
    label: name,
    kind: "ssh" as const,
    connected: true,
    state: "connected",
  });
  const sections = environmentSections(
    ["build-mini-1", "build-mini-2", "cmux16", "lane-1", "lane-2", "lane-3"].map(ssh),
  );
  expect(Object.fromEntries(sections)).toEqual({
    "build-mini-1": "mine",
    "build-mini-2": "mine",
    cmux16: "mine",
    "lane-1": "fleet",
    "lane-2": "fleet",
    "lane-3": "fleet",
  });
});

test("a chat's machine the daemon no longer lists is shown not connected, and is no pick", async () => {
  const { knownMachines, environmentReady } = await import("../src/agent-session/acpmux/environments");
  const machines = knownMachines(
    ["listed"],
    [
      { peer: "removed", host: "removed" },
      { peer: "listed", host: "listed" },
    ],
    { listed: "ssh" },
    [],
    { listed: true },
    { listed: "connected" },
  );
  expect(machines.map((machine) => [machine.id, machine.connected, environmentReady(machine)])).toEqual([
    ["listed", true, true],
    ["removed", false, false],
  ]);
});

test("Labs: Sandboxed is New Cloud Machine's other face, shown while ⌥ is held or searched, never a row of its own", async () => {
  const calls: unknown[][] = [];
  const runMode = { mode: "persistent", onMode: (mode: string) => calls.push(["mode", mode]) };
  await mount(true, { runMode });
  await openPicker();
  const before = rows().length;
  expect(doc().querySelector('.acpmux-env-popover [data-mode="sandboxed"]')).toBeNull();
  await press(doc().body, { key: "Alt", altKey: true });
  expect(rows()).toHaveLength(before);
  const sandbox = rows().find((row) => row.querySelector('[data-mode="sandboxed"]'))!;
  expect(rowText(sandbox)).toContain(t("composer.sandboxed"));
  await act(async () => sandbox.click());
  expect(calls).toEqual([["mode", "sandboxed"]]);
  await openPicker();
  await type("sandbox");
  expect(doc().querySelector('.acpmux-env-popover [data-mode="sandboxed"]')).toBeTruthy();
  // It is a match: no "no environment" line over it.
  expect(doc().querySelector(".acpmux-location-empty")).toBeNull();
  await press(doc().body, { key: "Escape" });
  // ⌥ already held as the control is pressed shows it too.
  await openPicker({ altKey: true });
  expect(doc().querySelector('.acpmux-env-popover [data-mode="sandboxed"]')).toBeTruthy();
});

test("Labs: with Sandboxed picked the control names it, no machine is checked, and a machine pick goes back to Persistent", async () => {
  const calls: unknown[][] = [];
  const runMode = { mode: "sandboxed", onMode: (mode: string) => calls.push(["mode", mode]) };
  const picks = await mount(true, { runMode });
  expect(computerButton()?.getAttribute("aria-label")).toBe(`${t("composer.environment")}: ${t("composer.sandboxed")}`);
  await openPicker();
  expect(doc().querySelector('.acpmux-env-popover [data-mode="sandboxed"][data-current]')).toBeTruthy();
  expect(machineRows().some((row) => row.querySelector("[data-current]"))).toBe(false);
  await act(async () => machineRows()[1]!.click());
  expect(calls).toEqual([["mode", "persistent"]]);
  expect(picks.at(-1)?.[0]).toBe("project");
  // ⌥ shows New Cloud Machine again while Sandboxed is the pick; picking it is Persistent too.
  calls.length = 0;
  await openPicker();
  await press(doc().body, { key: "Alt", altKey: true });
  expect(doc().querySelector('.acpmux-env-popover [data-mode="sandboxed"]')).toBeNull();
  const cloud = rows().find((row) => row.querySelector('[data-kind="cloud"]'))!;
  await act(async () => cloud.click());
  expect(calls).toEqual([["mode", "persistent"]]);
});

test("Auto shows its destination before opening and keeps explicit machines available", async () => {
  const calls = await mount(true, {
    auto: { detail: "gpu-box", kind: "ssh", selected: true, onPick: () => undefined },
  });
  expect(computerButton()?.textContent).toContain("Auto · gpu-box");
  await openPicker();
  const machine = machineRows().find((row) => rowText(row).includes("gpu-box"));
  expect(machine).toBeTruthy();
  await act(async () => machine!.click());
  expect(calls).toContainEqual(["project", "/home/dev/model", "gpu-box"]);
});

test("searching a machine skips Auto even when Auto would choose that machine", async () => {
  const calls = await mount(true, {
    auto: { detail: "gpu-box", kind: "ssh", selected: true, onPick: () => undefined },
  });
  await openPicker();
  const field = await typeKeys("gpu");
  expect(newRows().some((row) => rowText(row).includes("Auto"))).toBe(false);
  await press(field, { key: "Enter" });
  expect(calls).toContainEqual(["project", "/home/dev/model", "gpu-box"]);
});

test("searching Auto and pressing Enter selects it without an empty-state message", async () => {
  let picked = false;
  await mount(true, {
    auto: {
      detail: "This Mac",
      selected: false,
      onPick: () => {
        picked = true;
      },
    },
  });
  await openPicker();
  const field = await typeKeys("auto");
  expect(doc().querySelector(".acpmux-location-empty")).toBeNull();
  await press(field, { key: "Enter" });
  expect(picked).toBe(true);
});
