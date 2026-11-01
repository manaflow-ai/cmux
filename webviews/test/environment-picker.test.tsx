// The environment picker (preview, Settings > Advanced > Labs `labs.previewFeatures`): the composer
// location row's computer control becomes one searchable list of where a chat runs, as Claude's
// desktop app has it: Local, SSH and Cloud sections, ⌥⌘1–9 on the first nine rows, and New
// environment at the bottom, which opens the host's SSH connect flow; New Cloud Machine ends the
// Cloud section and opens the host's create flow. It defaults to this computer. The machines come
// from acpmux (`_acpmux/status` peers, by URL scheme, and the hosts its chats ran on); with
// previews off the row keeps its plain Computer menu.
import { afterAll, afterEach, beforeAll, beforeEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { translate as t } from "../src/agent-session/acpmux/i18n";
import { noChat } from "../src/gallery/fixtures/acpmux";
import { proseMirrorGlobals } from "../src/agent-session/acpmux/promptFieldTesting";

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
/// How often the picker asked the host to read the machines again (`onRefreshMachines`).
let refreshes = 0;
let updateProps: (extra: Record<string, unknown>) => Promise<void>;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", {
    pretendToBeVisual: true,
    url: "https://cmux.test/",
  });
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
    // The New Tab field is the composer's Markdown field (ProseMirror): it reads the selection and
    // its editor (Milkdown) signals its own steps with this window's CustomEvent on the global
    // event target, so that target is this window too.
    addEventListener: dom.window.addEventListener.bind(dom.window),
    removeEventListener: dom.window.removeEventListener.bind(dom.window),
    dispatchEvent: dom.window.dispatchEvent.bind(dom.window),
  });
  host = dom.window.document.getElementById("root")!;
});

// These pickers are a signed-in account's: the signed-out Sign in for Cloud row is
// environment-picker-cloud-machines.test.tsx's.
beforeEach(async () => {
  (await import("../src/agent-session/acpmux/cloudMachines")).setCloudMachinesForTestAccount(true);
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
});

afterAll(async () => {
  (await import("../src/agent-session/acpmux/cloudMachines")).setCloudMachinesForTestAccount(undefined);
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
  updateProps = async (extra) => {
    Object.assign(props, extra);
    await act(async () =>
      root!.render(
        <form className="acpmux-composer">
          <ComposerContext {...props} />
          <textarea aria-label="Prompt" />
        </form>,
      ),
    );
  };
  await updateProps({});
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

/// A connect choice's name, without the one-line description New Cloud Machine carries.
const choiceLabel = (button: Element) => button.querySelector(".acpmux-menu-label")?.textContent ?? button.textContent;

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

for (const environments of [false, true]) {
  // Base UI retains a closed popup during its exit transition; only an open popup can cover the ask.
  const menu = () =>
    doc().querySelector(
      environments ? ".acpmux-env-popover:not([data-closed])" : ".acpmux-location-menu:not([data-closed])",
    );
  test(`trust question closes an open destination picker (previews ${environments})`, async () => {
    await mount(environments);
    await openPicker();
    expect(menu()).not.toBeNull();
    await updateProps({ closeOnTrustAsk: true });
    expect(menu()).toBeNull();
    expect(computerButton()?.getAttribute("aria-expanded")).toBe("false");
    await openPicker();
    expect(menu()).toBeNull();
    await updateProps({ closeOnTrustAsk: false });
    await openPicker();
    expect(menu()).not.toBeNull();
  });
  for (const via of ["trigger", "opener"] as const) {
    test(`trust question prevents destination picker mounting via ${via} (previews ${environments})`, async () => {
      await mount(environments, { closeOnTrustAsk: true });
      const { flushSync } = await import("react-dom");
      const { openPicker: openRegisteredPicker } = await import("../src/agent-session/acpmux/pickerOpeners");
      const selector = environments ? ".acpmux-env-popover" : ".acpmux-location-menu";
      // Record even a node inserted and removed in the same commit/effect flush. Checking only
      // the final open state misses the popup stealing focus and refreshing before it closes.
      const observer = new dom.window.MutationObserver(() => {});
      observer.observe(doc().body, { childList: true, subtree: true });
      try {
        await act(async () => {
          flushSync(() => {
            if (via === "trigger") computerButton()!.click();
            else expect(openRegisteredPicker("Computer")).toBe(true);
          });
          // Assert before the outer act flush; mutation records also catch anything flushSync flushed.
          expect(Boolean(doc().querySelector(selector))).toBe(false);
          expect(refreshes).toBe(0);
          const insertedPopup = observer
            .takeRecords()
            .some((record) =>
              [...record.addedNodes].some(
                (node) =>
                  node instanceof dom.window.Element && (node.matches(selector) || node.querySelector(selector)),
              ),
            );
          expect(insertedPopup).toBe(false);
        });
        expect(Boolean(doc().querySelector(selector))).toBe(false);
        expect(refreshes).toBe(0);
      } finally {
        observer.disconnect();
      }
    });
  }
}

// A fresh home must offer setup without enabling the environments preview. The same
// plain Computer menu is usable from an existing local chat; its machine stays fixed.
for (const started of [false, true]) {
  test(`previews off: ${started ? "a local chat" : "a new chat"} with no other computers offers setup`, async () => {
    const calls = await mount(false, {
      started,
      sessions: [],
      peers: [],
      cloudMachines: [],
      summary: { sessionId: started ? "local-chat" : "", harness: "claude", hostKind: "local" },
    });
    await openPicker();
    const actions = () => [...doc().querySelectorAll<HTMLButtonElement>(".acpmux-location-choose")];
    expect(actions().map(choiceLabel)).toEqual([t("composer.addComputer"), t("composer.newCloudMachine")]);
    await act(async () => actions()[0]!.click());
    expect(calls).toEqual([["connect", "addMachine"]]);
    await openPicker();
    await act(async () => actions()[1]!.click());
    expect(calls).toEqual([
      ["connect", "addMachine"],
      ["connect", "cloud"],
    ]);
    expect(doc().querySelector(".acpmux-env-popover")).toBeNull();
  });
}

test("previews off: New Tab does not add setup beside existing computers", async () => {
  await mount(false, { connectOnlyWhenEmpty: true });
  await openPicker();
  expect(doc().querySelector(".acpmux-location-choose")).toBeNull();
});

test("previews off: an existing remote computer keeps the current connection footer", async () => {
  await mount(false);
  await openPicker();
  expect([...doc().querySelectorAll(".acpmux-location-choose")].map(choiceLabel)).toEqual([
    t("composer.connectSSH"),
    t("composer.newCloudMachine"),
  ]);
});

test("previews on: one list, This Mac first, numbered ⌥⌘1–9, defaulting to this computer", async () => {
  await mount(true);
  expect(computerButton()?.getAttribute("aria-label")).toBe(`${t("composer.environment")}: ${t("composer.thisMac")}`);
  await openPicker();
  const shown = machineRows();
  expect(shown.map((row) => row.querySelector(".acpmux-menu-label")?.textContent)).toEqual([
    t("composer.thisMac"),
    "gpu-box",
    "build-cloud",
    "cloud-1",
  ]);
  // This Mac's own name is its row's tooltip.
  expect(shown[0]!.querySelector(".acpmux-env-row")!.getAttribute("title")).toBe("cosmic-gray");
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
  // Cloud follows This Mac; it is the list's only action.
  expect(newRows().map((row) => row.querySelector(".acpmux-menu-label")?.textContent)).toEqual([t("composer.cloud")]);
  expect(rows()[1]).toBe(newRows()[0]);
});

// Leo, 2026-10-30, on a chat seeded onto a Cloud machine: "the ui is so ass in general for this tho".
// The host's `machineName` named the Cloud machine (`kind-aqua-sandpiper`), the page titled This Mac
// with it, and this Mac (cosmic-gray) was listed nowhere. This Mac is always this Mac's own name.
test("a Cloud machine is never This Mac's row, and This Mac keeps this Mac's name", async () => {
  const { thisMacName } = await import("../src/agent-session/acpmux/environments");
  const cloudChat = { sessionId: "", harness: "claude", host: "kind-aqua-sandpiper", hostKind: "cloud" };
  for (const [host, localMachineName, tooltip] of [
    ["current", "cosmic-gray", "cosmic-gray"],
    // A host that predates `localMachineName` sends the chat's machine as `machineName`.
    ["older", undefined, null],
  ] as const) {
    act(() => root?.unmount());
    await mount(true, {
      summary: cloudChat,
      sessions: [{ sessionId: "c", cwd: "/root/work", host: "kind-aqua-sandpiper", hostKind: "cloud", updatedAt: 0 }],
      localName: thisMacName(localMachineName, "kind-aqua-sandpiper", cloudChat),
    });
    await openPicker();
    const local = machineRows().filter((row) => row.querySelector('.acpmux-env-row[data-kind="local"]'));
    expect(
      local.map((row) => row.querySelector(".acpmux-menu-label")?.textContent),
      host,
    ).toEqual([t("composer.thisMac")]);
    expect(local[0]!.querySelector(".acpmux-env-row")!.getAttribute("title"), host).toBe(tooltip);
    // The Cloud machine is one of the other machines, after This Mac and Cloud, and the chat's pick.
    const sandpiper = machineRows().find((row) => rowText(row).startsWith("kind-aqua-sandpiper"))!;
    expect(sandpiper.querySelector(".acpmux-env-row")!.getAttribute("data-kind"), host).toBe("cloud");
    expect(machineRows().indexOf(sandpiper), host).toBeGreaterThan(0);
    expect(sandpiper.querySelector(".acpmux-env-row")!.hasAttribute("data-current"), host).toBe(true);
    await press(doc().querySelector(".acpmux-env-popover input")!, { key: "Escape" });
  }
});

test("This Mac's name is the host's own name, never the machine a seeded chat runs on", async () => {
  const { thisMacName } = await import("../src/agent-session/acpmux/environments");
  expect(thisMacName("cosmic-gray", "kind-aqua-sandpiper", { peer: "kind-aqua-sandpiper" })).toBe("cosmic-gray");
  // An older host: `machineName` is the chat's peer or Cloud host, so it is not this Mac's.
  expect(thisMacName(undefined, "kind-aqua-sandpiper", { peer: "kind-aqua-sandpiper" })).toBeUndefined();
  expect(
    thisMacName(undefined, "kind-aqua-sandpiper", { hostKind: "cloud", host: "kind-aqua-sandpiper" }),
  ).toBeUndefined();
  // An older host with a chat on this Mac: its `machineName` is this Mac's.
  expect(thisMacName(undefined, "cosmic-gray", { hostKind: "local", host: "cosmic-gray" })).toBe("cosmic-gray");
  expect(thisMacName(undefined, undefined)).toBeUndefined();
});

test("Cloud opens the host's New Cloud Machine flow", async () => {
  const calls = await mount(true, {
    sessions: [{ sessionId: "a", cwd: "/home/dev/model", host: "gpu-box", peer: "gpu-box", updatedAt: 0 }],
    peers: ["gpu-box"],
    peerKinds: { "gpu-box": "ssh" },
  });
  await openPicker();
  expect(machineRows().some((row) => row.querySelector('.acpmux-env-row[data-kind="cloud"]'))).toBe(false);
  const cloud = newRows()[0]!;
  expect(cloud.querySelector(".acpmux-menu-label")?.textContent).toBe(t("composer.cloud"));
  await act(async () => cloud.click());
  expect(calls).toEqual([["connect", "cloud"]]);
  expect(doc().querySelector(".acpmux-env-popover")).toBeNull();
});

/// Six SSH machines besides the ones `mount` lists: a list long enough for its search field.
const boxes = ["atlas", "birch", "cedar", "dune", "elm", "fern"];
const longList = {
  peers: [...status.peers.map((peer) => peer.name), ...boxes],
  peerKinds: { "gpu-box": "ssh", "cloud-1": "cloud", ...Object.fromEntries(boxes.map((name) => [name, "ssh"])) },
};

test("a long list's search field filters by name and section, keeping each machine's shortcut", async () => {
  await mount(true, longList);
  await openPicker();
  await type("cloud");
  const shown = machineRows();
  expect(shown.map((row) => rowText(row))).toEqual(["build-cloud⌥⌘9", `cloud-1${t("composer.envNotConnected")}`]);
  // Cloud matches its own name.
  expect(newRows().map((row) => row.querySelector(".acpmux-menu-label")?.textContent)).toEqual([t("composer.cloud")]);
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

test("each connect choice runs its own host action", async () => {
  const { CONNECT_ACTIONS } = await import("../src/agent-session/acpmux/environments");
  // Open Cloud… opens the Cloud page, whose Sizes and Plans view lists the plan's sizes.
  expect(CONNECT_ACTIONS).toEqual({
    ssh: "remote.connect",
    cloud: "newCloudMachine",
    cloudSignIn: "palette.auth.signIn",
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
  expect(machineRows().map(rowText)).toEqual([expect.stringContaining(t("composer.thisMac"))]);
  // One line: no account of what the move does under it.
  expect(newRows().map(rowText)).toEqual([t("composer.moveToCloud")]);
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

test("a started Cloud chat's picker keeps its machine's load warning", async () => {
  const { setComposerSettings, DEFAULT_COMPOSER } = await import("../src/agent-session/acpmux/composerSettings");
  setComposerSettings(DEFAULT_COMPOSER);
  await mount(true, {
    ...startedOn("cloud"),
    onOffload: () => {},
    peerResources: { "build-cloud": { ramFreeGB: 8, coresBusy: 14, cores: 10, busy: true, lowMemory: false } },
  });
  await openPicker();
  expect(machineRows()).toHaveLength(1);
  expect(machineRows()[0]!.querySelector('.acpmux-env-state[data-warning="true"]')?.textContent).toBe(
    t("composer.machineHighLoad", { busy: 14, cores: 10 }),
  );
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
  let calls = await mount(true, longList);
  await openPicker();
  await press(await typeKeys("gpu"), { key: "Enter" });
  expect(calls).toEqual([["project", "/home/dev/model", "gpu-box"]]);
  act(() => root?.unmount());
  // "clou" leaves Cloud alone with no machine named so, and Base UI moves its highlight onto it.
  calls = await mount(true, {
    sessions: [],
    peers: [...boxes, "gpu-box", "lab"],
    peerKinds: Object.fromEntries([...boxes, "gpu-box", "lab"].map((name) => [name, "ssh"])),
  });
  await openPicker();
  const field = await typeKeys("clou");
  expect(labels()).toEqual([t("composer.cloud")]);
  await press(field, { key: "Enter" });
  expect(calls).toEqual([]);
  await press(field, { key: "ArrowDown" });
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

// A new chat makes a worktree from its folder menu. The bar above the composer holds the folder and
// the machine only (Leo 2026-10-31, on a New Worktree control there: "who the f*** put worktree on there").
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
// New Worktree from the folder menu.
const newWorktreeFromMenu = async () => {
  const folder = host.querySelector<HTMLButtonElement>(
    `.acpmux-composer-context button[aria-label="${t("composer.folder")}"]`,
  );
  expect(folder, "no folder control").toBeTruthy();
  await act(async () => folder!.click());
  const action = [...doc().querySelectorAll<HTMLElement>(".acpmux-location-action")].find(
    (item) => item.textContent?.trim() === t("worktree.new"),
  );
  expect(action, "no New Worktree in the folder menu").toBeTruthy();
  await act(async () => action!.click());
};

test("previews on: New Worktree is in the folder menu, not a control beside the folder", async () => {
  const worktrees: string[] = [];
  await mount(true, { ...inFolder, onNewWorktree: (cwd: string) => worktrees.push(cwd) });
  expect(worktreeButton(), "a New Worktree control beside the folder").toBeUndefined();
  await newWorktreeFromMenu();
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
  await newWorktreeFromMenu();
  expect(asked).toEqual(["/Users/you/src/app"]);
  expect(folderName()).toContain("fox");
});

test("New Tab, previews on: the host's refusal shows above the card, and the folder stays", async () => {
  await mountNewTab(async () => {
    throw new Error("not a git repository");
  });
  await newWorktreeFromMenu();
  expect(host.querySelector('[role="alert"]')?.textContent).toContain("not a git repository");
  expect(folderName()).toBe("app");
});

test("New Tab, previews on: a slower worktree reply doesn't replace a newer choice", async () => {
  const replies: ((folder: string) => void)[] = [];
  await mountNewTab(() => new Promise<string | undefined>((resolve) => replies.push(resolve)));
  await newWorktreeFromMenu();
  await newWorktreeFromMenu();
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
  await newWorktreeFromMenu();
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
  // No section headers: one hairline under This Mac and Cloud.
  expect(rows().filter((row) => row.querySelector("[data-divider]"))).toEqual([shown[1]!]);
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
  // A greyed machine stays in its place, among its section's machines, and is no pick: the list stays open.
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

test("the plain Computer menu warns when a remote machine reaches its CPU budget", async () => {
  await mount(false, {
    peerResources: {
      "gpu-box": { ramFreeGB: 8, coresBusy: 14, cores: 10, busy: true, lowMemory: false },
    },
  });
  await openPicker();
  const row = [...doc().querySelectorAll<HTMLElement>(".acpmux-location-menu .acpmux-menu-item")].find(
    (item) => item.querySelector(".acpmux-menu-label")?.textContent === "gpu-box",
  )!;
  expect(row.querySelector(".acpmux-location-name")?.getAttribute("data-warning")).toBe("true");
  expect(row.querySelector(".acpmux-menu-description")?.textContent).toBe(
    t("composer.machineHighLoad", { busy: 14, cores: 10 }),
  );
});

test("the plain Computer menu warns with free memory when CPU is fine", async () => {
  await mount(false, {
    peerResources: {
      "gpu-box": { ramFreeGB: 1.2, coresBusy: 2, cores: 10, busy: false, lowMemory: true },
    },
  });
  await openPicker();
  const row = [...doc().querySelectorAll<HTMLElement>(".acpmux-location-menu .acpmux-menu-item")].find(
    (item) => item.querySelector(".acpmux-menu-label")?.textContent === "gpu-box",
  )!;
  expect(row.querySelector(".acpmux-location-name")?.getAttribute("data-warning")).toBe("true");
  expect(row.querySelector(".acpmux-menu-description")?.textContent).toBe(
    t("composer.machineLowMemory", { free: "1.2" }),
  );
});

test("a healthy machine stays quiet and the warning setting can hide a warning", async () => {
  await mount(false, {
    peerResources: {
      "gpu-box": { ramFreeGB: 8, coresBusy: 2, cores: 10, busy: false, lowMemory: false },
    },
  });
  await openPicker();
  let row = [...doc().querySelectorAll<HTMLElement>(".acpmux-location-menu .acpmux-menu-item")].find(
    (item) => item.querySelector(".acpmux-menu-label")?.textContent === "gpu-box",
  )!;
  expect(row.querySelector(".acpmux-location-name")?.getAttribute("data-warning")).toBeNull();
  expect(row.querySelector(".acpmux-menu-description")).toBeNull();

  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
  await mount(false, {
    showMachineLoadWarnings: false,
    peerResources: {
      "gpu-box": { ramFreeGB: 1.2, coresBusy: 14, cores: 10, busy: true, lowMemory: true },
    },
  });
  await openPicker();
  row = [...doc().querySelectorAll<HTMLElement>(".acpmux-location-menu .acpmux-menu-item")].find(
    (item) => item.querySelector(".acpmux-menu-label")?.textContent === "gpu-box",
  )!;
  expect(row.querySelector(".acpmux-location-name")?.getAttribute("data-warning")).toBeNull();
  expect(row.querySelector(".acpmux-menu-description")).toBeNull();
});

test("a warning is withheld while a machine is not ready", async () => {
  await mount(false, {
    peerConnected: { "gpu-box": false },
    peerResources: {
      "gpu-box": { ramFreeGB: 1.2, coresBusy: 14, cores: 10, busy: true, lowMemory: true },
    },
  });
  await openPicker();
  const row = [...doc().querySelectorAll<HTMLElement>(".acpmux-location-menu .acpmux-menu-item")].find(
    (item) => item.querySelector(".acpmux-menu-label")?.textContent === "gpu-box",
  )!;
  expect(row.querySelector(".acpmux-location-name")?.getAttribute("data-warning")).toBeNull();
  expect(row.querySelector(".acpmux-menu-description")?.textContent).toBe(t("composer.envNotConnected"));
});

test("turning the warning setting off updates an already-open menu", async () => {
  const { setComposerSettings, DEFAULT_COMPOSER } = await import("../src/agent-session/acpmux/composerSettings");
  setComposerSettings(DEFAULT_COMPOSER);
  await mount(false, {
    peerResources: {
      "gpu-box": { ramFreeGB: 1.2, coresBusy: 14, cores: 10, busy: true, lowMemory: true },
    },
  });
  await openPicker();
  const row = () =>
    [...doc().querySelectorAll<HTMLElement>(".acpmux-location-menu .acpmux-menu-item")].find(
      (item) => item.querySelector(".acpmux-menu-label")?.textContent === "gpu-box",
    )!;
  expect(row().querySelector(".acpmux-location-name")?.getAttribute("data-warning")).toBe("true");
  await act(async () => setComposerSettings({ showMachineLoadWarnings: false }));
  expect(row().querySelector(".acpmux-location-name")?.getAttribute("data-warning")).toBeNull();
  expect(row().querySelector(".acpmux-menu-description")).toBeNull();
  setComposerSettings(DEFAULT_COMPOSER);
});

test("the environment picker warns on a ready machine at its CPU budget, as the plain menu does", async () => {
  const { setComposerSettings, DEFAULT_COMPOSER } = await import("../src/agent-session/acpmux/composerSettings");
  setComposerSettings(DEFAULT_COMPOSER);
  await mount(true, {
    peerResources: {
      "gpu-box": { ramFreeGB: 8, coresBusy: 14, cores: 10, busy: true, lowMemory: false },
    },
  });
  await openPicker();
  const row = () =>
    [...doc().querySelectorAll<HTMLElement>(".acpmux-env-popover .acpmux-env-row")].find(
      (item) => item.querySelector(".acpmux-menu-label")?.textContent === "gpu-box",
    )!;
  const warning = row().querySelector('.acpmux-env-state[data-warning="true"]');
  expect(warning?.textContent).toBe(t("composer.machineHighLoad", { busy: 14, cores: 10 }));
  await act(async () => setComposerSettings({ showMachineLoadWarnings: false }));
  expect(row().querySelector('.acpmux-env-state[data-warning="true"]')).toBeNull();
  setComposerSettings(DEFAULT_COMPOSER);
});

test("the environment picker withholds a warning while a machine is not ready", async () => {
  await mount(true, {
    peerConnected: { "gpu-box": false },
    peerResources: {
      "gpu-box": { ramFreeGB: 1.2, coresBusy: 14, cores: 10, busy: true, lowMemory: true },
    },
  });
  await openPicker();
  const row = [...doc().querySelectorAll<HTMLElement>(".acpmux-env-popover .acpmux-env-row")].find(
    (item) => item.querySelector(".acpmux-menu-label")?.textContent === "gpu-box",
  )!;
  expect(row.querySelector('.acpmux-env-state[data-warning="true"]')).toBeNull();
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

test("Labs: Sandboxed is Cloud's other face, shown while ⌥ is held or searched, never a row of its own", async () => {
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
  // ⌥ already held as the control is pressed shows it too.
  await openPicker({ altKey: true });
  expect(doc().querySelector('.acpmux-env-popover [data-mode="sandboxed"]')).toBeTruthy();
});

test("Labs: a long list's search for Sandboxed shows it in Cloud's place", async () => {
  await mount(true, { ...longList, runMode: { mode: "persistent", onMode: () => undefined } });
  await openPicker();
  await type("sandbox");
  expect(doc().querySelector('.acpmux-env-popover [data-mode="sandboxed"]')).toBeTruthy();
  // It is a match: no "no environment" line over it.
  expect(doc().querySelector(".acpmux-location-empty")).toBeNull();
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
  // ⌥ shows Cloud again while Sandboxed is the pick; picking it makes Cloud where the chat runs.
  calls.length = 0;
  await openPicker();
  await press(doc().body, { key: "Alt", altKey: true });
  expect(doc().querySelector('.acpmux-env-popover [data-mode="sandboxed"]')).toBeNull();
  const cloud = rows().find((row) => row.querySelector('.acpmux-env-row[data-mode="cloud"]'))!;
  await act(async () => cloud.click());
  expect(calls).toEqual([["mode", "cloud"]]);
});

// Leo, 2026-10-31, on the picker's menu (Search environments, an Auto row, This Mac, Cloud and VMs
// and New environment headers, Cloud's long second line, New Cloud Machine…, Open Cloud…, Create
// environment): "bro this text is so fucking stupid why the fuck IS THERE SO MUCH BULLSHIT JUST A
// LITTLE CLOUD ICON OR FUCKING THE SELECTION YOU KNOW WHATEVER WORKS JUST NOT THE FUCKING EXISTING
// GAHHH". As Codex's "Where should this chat run?": This Mac and Cloud, other machines only when the
// person has some, one line each, no headers; the setup actions live off the list.
const labels = () => rows().map((row) => row.querySelector(".acpmux-menu-label")?.textContent ?? "");
const alone = { sessions: [], peers: [], peerKinds: {}, peerConnected: {} };

test("Leo's menu: This Mac and Cloud, then the other machines only when there are some", async () => {
  await mount(true, alone);
  await openPicker();
  expect(labels()).toEqual([t("composer.thisMac"), t("composer.cloud")]);
  act(() => root?.unmount());
  await mount(true);
  await openPicker();
  expect(labels()).toEqual([t("composer.thisMac"), t("composer.cloud"), "gpu-box", "build-cloud", "cloud-1"]);
  // One hairline splits them, over the first other machine.
  expect(rows().map((row) => row.querySelector(".acpmux-env-row")!.hasAttribute("data-divider"))).toEqual([
    false,
    false,
    true,
    false,
    false,
  ]);
  // This Mac keeps ⌥⌘1; Cloud is no machine, so it takes no digit.
  expect(rows().map((row) => row.querySelector(".acpmux-env-key")?.textContent)).toEqual([
    "⌥⌘1",
    undefined,
    "⌥⌘2",
    "⌥⌘3",
    undefined,
  ]);
});

test("Leo's menu: no section headers, no second lines, and no setup rows", async () => {
  await mount(true, { runMode: { mode: "persistent", onMode: () => undefined } });
  await openPicker();
  const popover = doc().querySelector<HTMLElement>(".acpmux-env-popover")!;
  expect(popover.querySelectorAll("[data-section], [data-first-section]")).toHaveLength(0);
  expect(popover.querySelectorAll(".acpmux-env-detail")).toHaveLength(0);
  // A row's text is its one label: no line under it.
  for (const row of rows()) expect(row.querySelectorAll(".acpmux-menu-text > *"), rowText(row)).toHaveLength(1);
  const text = popover.textContent ?? "";
  for (const key of [
    "composer.newCloudMachine",
    "composer.newCloudMachineDetail",
    "composer.openCloud",
    "composer.connectSSH",
    "composer.connectPhone",
    "composer.addMachine",
    "composer.newEnvironment",
    "composer.envMine",
    "composer.envFleet",
    "environment.create",
  ] as const)
    expect(text, key).not.toContain(t(key));
  expect(text).not.toContain("Auto ·");
});

test("Leo's menu: a search field only from eight machines", async () => {
  const { ENVIRONMENT_SEARCH_MIN } = await import("../src/agent-session/acpmux/EnvironmentPicker");
  expect(ENVIRONMENT_SEARCH_MIN).toBe(8);
  await mount(true);
  await openPicker();
  const popover = () => doc().querySelector<HTMLElement>(".acpmux-env-popover")!;
  expect(popover().classList.contains("acpmux-env-searchless")).toBe(true);
  expect(popover().querySelector("input")!.getAttribute("placeholder")).toBeNull();
  // Keys typed into a list with no field filter nothing.
  await type("gpu");
  expect(labels()).toHaveLength(5);
  act(() => root?.unmount());
  const many = Array.from({ length: 8 }, (_, index) => `box-${index + 1}`);
  await mount(true, { peers: many, peerKinds: Object.fromEntries(many.map((name) => [name, "ssh"])) });
  await openPicker();
  expect(popover().classList.contains("acpmux-env-searchless")).toBe(false);
  expect(popover().querySelector("input")!.getAttribute("placeholder")).toBe(t("composer.environmentSearch"));
  await type("box-3");
  expect(labels()).toEqual(["box-3"]);
});

test("Leo's menu: the setup actions moved to the control's right-click menu, each running its host action", async () => {
  const calls = await mount(true);
  const items = () => [...doc().querySelectorAll<HTMLElement>('[role="menu"] [role="menuitem"]')];
  const rightClick = async () =>
    act(async () =>
      computerButton()!.dispatchEvent(
        new dom.window.MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 10, clientY: 10 }),
      ),
    );
  await rightClick();
  expect(items().map((item) => item.textContent)).toEqual([
    t("composer.newCloudMachine"),
    t("composer.openCloud"),
    t("composer.connectSSH"),
    t("composer.addMachine"),
    t("composer.connectPhone"),
  ]);
  for (const index of [0, 1, 2, 3, 4]) {
    if (index > 0) await rightClick();
    await act(async () => items()[index]!.click());
  }
  expect(calls).toEqual([
    ["connect", "cloud"],
    ["connect", "cloudPage"],
    ["connect", "ssh"],
    ["connect", "addMachine"],
    ["connect", "phone"],
  ]);
});

test("Leo's menu: the moved actions keep their homes in the app (palette, File menu, Settings, Cloud page)", async () => {
  const { readFileSync } = await import("node:fs");
  const { CONNECT_ACTIONS } = await import("../src/agent-session/acpmux/environments");
  const catalog = (name: string) =>
    readFileSync(
      new URL(`../../Packages/macOS/CmuxNext/Sources/CmuxNextActions/Catalog/${name}.swift`, import.meta.url),
      "utf8",
    );
  const descriptor = (source: string, id: string) => {
    const at = source.indexOf(`id: "${id}"`);
    expect(at, id).toBeGreaterThan(-1);
    const end = source.indexOf("ActionDescriptor(", at);
    return source.slice(at, end < 0 ? undefined : end);
  };
  const cloud = catalog("CloudActionCatalog");
  const remote = catalog("RemoteActionCatalog");
  const pane = catalog("PaneActionCatalog");
  // New Cloud Machine…, SSH… and Connect Phone… are command palette rows; Add Machine… is in the
  // File menu and Settings > Devices; Open Cloud… is the profile menu's Cloud row and the palette's.
  expect(descriptor(cloud, CONNECT_ACTIONS.cloud)).toContain(".palette");
  expect(descriptor(cloud, CONNECT_ACTIONS.phone)).toContain(".palette");
  expect(descriptor(remote, CONNECT_ACTIONS.ssh)).toContain(".palette");
  expect(descriptor(remote, CONNECT_ACTIONS.addMachine)).toContain("mainMenu: .file");
  expect(descriptor(pane, CONNECT_ACTIONS.cloudPage)).toContain(".palette");
});

test("Leo's menu: the control shows the current choice, its icon this Mac's or the machine's", async () => {
  await mount(true);
  const face = () => computerButton()!;
  expect(face().querySelector(".acpmux-env-icon")!.getAttribute("data-kind")).toBe("local");
  expect(face().querySelector(".acpmux-location-label")!.textContent).toBe(t("composer.thisMac"));
  await openPicker();
  await act(async () =>
    rows()
      .find((row) => rowText(row).startsWith("build-cloud"))!
      .click(),
  );
  expect(face().querySelector(".acpmux-env-icon")!.getAttribute("data-kind")).toBe("cloud");
  expect(face().querySelector(".acpmux-location-label")!.textContent).toBe("build-cloud");
});
