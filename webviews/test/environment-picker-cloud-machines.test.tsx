// The account's Cloud machines in the composer's machine list (cloudMachines.ts). Leo, 2026-10-26:
// "the dropdown should show the states of stuff when you've done the acp things or any kind of
// connectivity." acpmux lists only the machines it has a link to, so a paused Cloud machine was
// missing; the app's list (`cloudMachine.list`) adds the ones acpmux does not list, each with its
// stage, and a pick resumes a paused one or opens the machine.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { translate as t } from "../src/agent-session/acpmux/i18n";
import type { CloudMachine } from "../src/agent-session/acpmux/cloudMachines";

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
  });
  host = dom.window.document.getElementById("root")!;
});

afterEach(async () => {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
  delete (dom.window as unknown as { webkit?: unknown }).webkit;
  (await import("../src/agent-session/acpmux/cloudMachines")).setCloudMachinesForTest([]);
});

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

/// The account's machines: `gpu-box` is also an acpmux peer, so acpmux's row stays the only one.
const account: CloudMachine[] = [
  { id: "vm-paused", name: "build box", stage: "paused" },
  { id: "vm-ready", name: "eval box", stage: "ready" },
  { id: "vm-boot", name: "fresh box", stage: "booting" },
  { id: "vm-peer", name: "GPU-BOX", stage: "ready" },
];

async function mount(environments: boolean, extra: Record<string, unknown> = {}) {
  const { createRoot } = await import("react-dom/client");
  const { ComposerContext } = await import("../src/agent-session/acpmux/ComposerContext");
  const picks: unknown[][] = [];
  const props = {
    environments,
    summary: { sessionId: "", harness: "claude", host: "This Mac", hostKind: "local" },
    sessions: [],
    peers: ["gpu-box"],
    peerKinds: { "gpu-box": "ssh" },
    peerConnected: { "gpu-box": true },
    peerStates: { "gpu-box": "connected" },
    localName: "this-mac",
    projectChoices: [{ cwd: "/Users/you/src/cmux", label: "cmux" }],
    onProject: (cwd: string, peer?: string) => picks.push(["project", cwd, peer]),
    onComputer: (computer: string) => picks.push(["computer", computer]),
    onConnect: () => undefined,
    onCloudMachine: (machine: CloudMachine) => picks.push(["cloud", machine.id]),
    cloudMachines: account,
    ...extra,
  } as unknown as Parameters<typeof ComposerContext>[0];
  root = createRoot(host);
  await act(async () => root!.render(<ComposerContext {...props} />));
  return picks;
}

const doc = () => dom.window.document;
const computerButton = () =>
  [...host.querySelectorAll<HTMLButtonElement>(".acpmux-location-button")].find((button) =>
    [t("composer.environment"), t("composer.computer")].some((name) =>
      (button.getAttribute("aria-label") ?? "").startsWith(name + ":"),
    ),
  );
async function openPicker() {
  const button = computerButton();
  expect(button, "no computer control").toBeTruthy();
  await act(async () => {
    button!.dispatchEvent(new dom.window.MouseEvent("pointerdown", { bubbles: true }));
    button!.click();
  });
}
/// Every machine: Machines… on the control's right-click menu (the main list is This Mac and Cloud).
async function openMachines() {
  await act(async () =>
    computerButton()!.dispatchEvent(
      new dom.window.MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 10, clientY: 10 }),
    ),
  );
  const item = [...doc().querySelectorAll<HTMLElement>('[role="menu"] [role="menuitem"]')].find(
    (candidate) => candidate.textContent === t("composer.machinesList"),
  );
  expect(item, "no Machines… item").toBeTruthy();
  await act(async () => item!.click());
}
const label = (row: Element) => row.querySelector(".acpmux-menu-label")?.textContent ?? row.textContent;
const pickerRows = () =>
  [...doc().querySelectorAll<HTMLElement>(".acpmux-env-popover .acpmux-menu-item")].filter((row) =>
    row.querySelector(".acpmux-env-row:not(.acpmux-env-new)"),
  );

test("signed out keeps Cloud and adds a sign-in row after it", async () => {
  const { setCloudMachinesForTestAccount } = await import("../src/agent-session/acpmux/cloudMachines");
  setCloudMachinesForTestAccount(false);
  const calls: string[] = [];
  await mount(true, { cloudMachines: [], onConnect: (kind: string) => calls.push(kind) });
  await openPicker();
  const rows = [...doc().querySelectorAll<HTMLElement>(".acpmux-location-menu .acpmux-menu-item")].filter((item) =>
    item.querySelector(".acpmux-location-name"),
  );
  // The list is This Mac and Cloud; New Cloud Machine… and SSH… are on the control's right-click menu.
  const names = rows.map(label);
  expect(names).toContain(t("composer.cloud"));
  expect(names.indexOf("Sign in for Cloud")).toBe(names.indexOf(t("composer.cloud")) + 1);
  await act(async () => rows.find((row) => label(row) === "Sign in for Cloud")!.click());
  // Sign-in only: New Cloud Machine (`cloud`) would sign in and then create a machine.
  expect(calls).toEqual(["cloudSignIn"]);
  const { CONNECT_ACTIONS } = await import("../src/agent-session/acpmux/environments");
  expect(CONNECT_ACTIONS.cloudSignIn).toBe("palette.auth.signIn");
});

test("an absent Cloud account state still offers sign-in, while an explicit signed-in state does not", async () => {
  const { setCloudMachinesForTestAccount } = await import("../src/agent-session/acpmux/cloudMachines");
  const rows = async () => {
    await openPicker();
    return [...doc().querySelectorAll<HTMLElement>(".acpmux-location-menu .acpmux-menu-item")].filter((item) =>
      item.querySelector(".acpmux-location-name"),
    );
  };
  setCloudMachinesForTestAccount(undefined);
  await mount(true, { cloudMachines: [], onConnect: () => undefined });
  expect((await rows()).map(label)).toContain("Sign in for Cloud");

  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
  setCloudMachinesForTestAccount(true);
  await mount(true, { cloudMachines: [], onConnect: () => undefined });
  expect((await rows()).map(label)).not.toContain("Sign in for Cloud");
});

test("the plain Computer picker offers Cloud sign-in before the account reply", async () => {
  const { setCloudMachinesForTestAccount } = await import("../src/agent-session/acpmux/cloudMachines");
  setCloudMachinesForTestAccount(undefined);
  const calls: string[] = [];
  await mount(false, { peers: [], cloudMachines: [], onConnect: (kind: string) => calls.push(kind) });
  await openPicker();
  const items = [...doc().querySelectorAll<HTMLElement>(".acpmux-location-menu .acpmux-menu-item")];
  const labels = items.map(label);
  expect(labels).toContain("Sign in for Cloud");
  await act(async () => items.find((row) => label(row) === "Sign in for Cloud")!.click());
  expect(calls).toEqual(["cloudSignIn"]);
  expect(labels).toContain(t("composer.addComputer"));
  expect(labels).toContain(t("composer.newCloudMachine"));

  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
  setCloudMachinesForTestAccount(true);
  await mount(false, { peers: [], cloudMachines: [], onConnect: () => undefined });
  await openPicker();
  expect([...doc().querySelectorAll<HTMLElement>(".acpmux-location-menu .acpmux-menu-item")].map(label)).not.toContain(
    "Sign in for Cloud",
  );
});

for (const result of ["failed", "signed out"] as const) {
  test(`a ${result} revalidation removes the previous account's machines and offers sign-in`, async () => {
    const { refreshCloudMachines } = await import("../src/agent-session/acpmux/cloudMachines");
    const posted: { method: string; params: unknown }[] = [];
    answerAsTheApp(posted);
    await mount(false, { cloudMachines: undefined, peers: [] });
    await openPicker();
    const labels = () => [...doc().querySelectorAll(".acpmux-location-menu .acpmux-menu-item")].map(label);
    expect(labels()).toContain("build box");
    expect(labels()).not.toContain("Sign in for Cloud");

    // Use the same native bridge as opening the picker, with no injected account state.
    answerAsTheApp(posted, () => {
      if (result === "failed") return { ok: false, error: { code: "unavailable" } };
      return { ok: true, value: { signedIn: false, loaded: false, machines: [] } };
    });
    await act(async () => refreshCloudMachines());
    expect(labels()).not.toContain("build box");
    expect(labels()).toContain("Sign in for Cloud");
    expect(labels()).toContain(t("composer.newCloudMachine"));
  });
}

test("a reply lists the account's machines only once the app holds the signed-in account's list", async () => {
  const { cloudMachinesFromReply } = await import("../src/agent-session/acpmux/cloudMachines");
  const machines = [{ id: "vm-1", name: "one", stage: "paused" }];
  expect(cloudMachinesFromReply({ signedIn: true, loaded: true, machines })).toEqual(machines);
  expect(cloudMachinesFromReply({ signedIn: true, loaded: false, machines })).toEqual([]);
  expect(cloudMachinesFromReply({ signedIn: false, loaded: true, machines })).toEqual([]);
  expect(cloudMachinesFromReply(null)).toEqual([]);
  expect(
    cloudMachinesFromReply({
      signedIn: true,
      loaded: true,
      machines: [...machines, { id: "", name: "x", stage: "ready" }, { id: "vm-2", name: 3 }, null],
    }),
  ).toEqual(machines);
});

test("a machine acpmux already lists keeps acpmux's row; a paused one resumes, any other opens", async () => {
  const { cloudMachineRows, cloudMachineAction } = await import("../src/agent-session/acpmux/cloudMachines");
  const rows = cloudMachineRows(account, [{ id: "gpu-box", label: "gpu-box" }]);
  expect(rows.map((row) => row.label)).toEqual(["build box", "eval box", "fresh box"]);
  expect(rows.every((row) => row.kind === "cloud" && row.connected === false)).toBe(true);
  expect(account.map(cloudMachineAction)).toEqual(["resume", "open", "open", "open"]);
});

test("a list read in flight when a pick runs is not the one that shows the new stage", async () => {
  const { refreshCloudMachines, runCloudMachine } = await import("../src/agent-session/acpmux/cloudMachines");
  const calls: string[] = [];
  let release!: () => void;
  const held = new Promise<void>((resolve) => (release = resolve));
  const call = async (method: string) => {
    calls.push(method);
    if (method === "cloudMachine.list" && calls.length === 1) await held;
    return method === "cloudMachine.list" ? { signedIn: true, loaded: true, machines: [] } : null;
  };
  const before = refreshCloudMachines(call);
  const picked = runCloudMachine(account[0]!, call);
  release();
  await Promise.all([before, picked]);
  expect(calls).toEqual(["cloudMachine.list", "cloudMachine.resume", "cloudMachine.list"]);
});

test("a pick asks the app to resume or open the machine, then reads the list again", async () => {
  const { runCloudMachine } = await import("../src/agent-session/acpmux/cloudMachines");
  const calls: unknown[][] = [];
  const call = async (method: string, params?: Record<string, unknown>) => {
    calls.push([method, params]);
    return method === "cloudMachine.list" ? { signedIn: true, loaded: true, machines: [] } : null;
  };
  await runCloudMachine(account[0]!, call);
  await runCloudMachine(account[1]!, call);
  expect(calls).toEqual([
    ["cloudMachine.resume", { id: "vm-paused" }],
    ["cloudMachine.list", {}],
    ["cloudMachine.open", { id: "vm-ready" }],
    ["cloudMachine.list", {}],
  ]);
});

test("previews on: the account's machines join the other machines with their stage, a pick but no ⌥⌘ digit", async () => {
  const picks = await mount(true);
  await openMachines();
  const rows = pickerRows();
  expect(rows.map(label)).toEqual([t("composer.thisMac"), "gpu-box", "build box", "eval box", "fresh box"]);
  const cloud = rows.slice(2);
  expect(cloud.map((row) => row.querySelector(".acpmux-env-state")?.textContent)).toEqual([
    t("composer.envPausedResume"),
    t("composer.envOpenMachine"),
    t("composer.envStarting"),
  ]);
  expect(cloud.every((row) => row.querySelector('.acpmux-env-row[data-kind="cloud"]'))).toBe(true);
  expect(cloud.some((row) => row.querySelector('[data-ready="false"], [aria-disabled="true"], .acpmux-env-key'))).toBe(
    false,
  );
  await act(async () => cloud[0]!.click());
  expect(picks).toEqual([["cloud", "vm-paused"]]);
  // No chat moved yet: the control names the machine the pick waits for, as starting.
  expect(computerButton()?.getAttribute("aria-label")).toBe(
    `${t("composer.environment")}: build box · ${t("composer.envStarting")}`,
  );
});

test("a Cloud machine picked while paused takes the chat once acpmux lists it ready", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ComposerContext } = await import("../src/agent-session/acpmux/ComposerContext");
  const picks: unknown[][] = [];
  const base = {
    environments: true,
    summary: { sessionId: "", harness: "claude", host: "This Mac", hostKind: "local" },
    sessions: [],
    localName: "this-mac",
    projectChoices: [{ cwd: "/Users/you/src/cmux", label: "cmux" }],
    onProject: (cwd: string, peer?: string) => picks.push(["project", cwd, peer]),
    onComputer: (computer: string) => picks.push(["computer", computer]),
    onConnect: () => undefined,
    onCloudMachine: (machine: CloudMachine) => picks.push(["cloud", machine.id]),
  };
  const before = {
    ...base,
    peers: ["gpu-box"],
    peerKinds: { "gpu-box": "ssh" },
    peerConnected: { "gpu-box": true },
    peerStates: { "gpu-box": "connected" },
    cloudMachines: account,
  } as unknown as Parameters<typeof ComposerContext>[0];
  root = createRoot(host);
  await act(async () => root!.render(<ComposerContext {...before} />));
  await openMachines();
  await act(async () =>
    pickerRows()
      .find((row) => label(row) === "build box")!
      .click(),
  );
  // Still linking: acpmux lists it, but not connected yet. Nothing moves.
  const linking = {
    ...before,
    peers: ["gpu-box", "build box"],
    peerKinds: { "gpu-box": "ssh", "build box": "cloud" },
    peerConnected: { "gpu-box": true, "build box": false },
    peerStates: { "gpu-box": "connected", "build box": "connecting" },
    cloudMachines: [{ ...account[0]!, stage: "booting" }, ...account.slice(1)],
  } as unknown as Parameters<typeof ComposerContext>[0];
  await act(async () => root!.render(<ComposerContext {...linking} />));
  expect(picks).toEqual([["cloud", "vm-paused"]]);
  // Connected: the chat starts there, and the control names it.
  const ready = {
    ...linking,
    peerConnected: { "gpu-box": true, "build box": true },
    peerStates: { "gpu-box": "connected", "build box": "connected" },
  } as unknown as Parameters<typeof ComposerContext>[0];
  await act(async () => root!.render(<ComposerContext {...ready} />));
  expect(picks).toEqual([
    ["cloud", "vm-paused"],
    ["computer", "build box"],
  ]);
  expect(computerButton()?.getAttribute("aria-label")).toBe(`${t("composer.environment")}: build box`);
});

test("another pick ends the wait for a Cloud machine", async () => {
  const picks = await mount(true);
  await openMachines();
  await act(async () =>
    pickerRows()
      .find((row) => label(row) === "build box")!
      .click(),
  );
  await openMachines();
  await act(async () =>
    pickerRows()
      .find((row) => label(row) === "gpu-box")!
      .click(),
  );
  expect(picks).toEqual([
    ["cloud", "vm-paused"],
    ["computer", "gpu-box"],
  ]);
  expect(computerButton()?.getAttribute("aria-label")).toBe(`${t("composer.environment")}: gpu-box`);
});

/// The props of a New Tab composer waiting on `build box` (picked while paused), for a rerender.
async function waitOnBuildBox() {
  const { ComposerContext } = await import("../src/agent-session/acpmux/ComposerContext");
  const picks = await mount(true);
  await openMachines();
  await act(async () =>
    pickerRows()
      .find((row) => label(row) === "build box")!
      .click(),
  );
  const props = (extra: Record<string, unknown>) =>
    ({
      environments: true,
      summary: { sessionId: "", harness: "claude", host: "This Mac", hostKind: "local" },
      sessions: [],
      peers: ["gpu-box"],
      peerKinds: { "gpu-box": "ssh" },
      peerConnected: { "gpu-box": true },
      peerStates: { "gpu-box": "connected" },
      localName: "this-mac",
      projectChoices: [{ cwd: "/Users/you/src/cmux", label: "cmux" }],
      onProject: (cwd: string, peer?: string) => picks.push(["project", cwd, peer]),
      onComputer: (computer: string) => picks.push(["computer", computer]),
      onConnect: () => undefined,
      onCloudMachine: (machine: CloudMachine) => picks.push(["cloud", machine.id]),
      cloudMachines: account,
      ...extra,
    }) as unknown as Parameters<typeof ComposerContext>[0];
  const render = (extra: Record<string, unknown>) =>
    act(async () => root!.render(<ComposerContext {...props(extra)} />));
  const ready = {
    peers: ["gpu-box", "build box"],
    peerKinds: { "gpu-box": "ssh", "build box": "cloud" },
    peerConnected: { "gpu-box": true, "build box": true },
    peerStates: { "gpu-box": "connected", "build box": "connected" },
  };
  return { picks, render, ready };
}

test("a Cloud machine that fails to start ends the wait: the control says so and nothing moves", async () => {
  const { picks, render, ready } = await waitOnBuildBox();
  await render({ cloudMachines: [{ ...account[0]!, stage: "failed" }, ...account.slice(1)] });
  expect(computerButton()?.getAttribute("aria-label")).toBe(
    `${t("composer.environment")}: build box · ${t("switch.failedShort")}`,
  );
  await render({ ...ready, cloudMachines: [{ ...account[0]!, stage: "failed" }, ...account.slice(1)] });
  expect(picks).toEqual([["cloud", "vm-paused"]]);
});

test("a chat change drops the wait for good, even when the chat comes back to the same key", async () => {
  const { picks, render, ready } = await waitOnBuildBox();
  await render({ summary: { sessionId: "other-chat", harness: "claude", host: "This Mac", hostKind: "local" } });
  await render({});
  await render(ready);
  expect(picks).toEqual([["cloud", "vm-paused"]]);
  expect(computerButton()?.getAttribute("aria-label")).not.toContain(t("composer.envStarting"));
});

test("a machine the account stops listing ends the wait for good, even when it is listed again", async () => {
  const { picks, render, ready } = await waitOnBuildBox();
  await render({ cloudMachines: account.slice(1) });
  await render({ ...ready, cloudMachines: account });
  expect(picks).toEqual([["cloud", "vm-paused"]]);
});

test("a refused resume shows the machine as Couldn't start, not Starting… for ever", async () => {
  const { runCloudMachine, setCloudMachinesForTest } = await import("../src/agent-session/acpmux/cloudMachines");
  setCloudMachinesForTest(account);
  const call = async (method: string) => {
    if (method === "cloudMachine.resume") throw new Error("refused");
    return { signedIn: true, loaded: true, machines: account };
  };
  await act(async () => {
    await runCloudMachine(account[0]!, call);
  });
  await mount(true, { cloudMachines: undefined });
  await openMachines();
  const row = pickerRows().find((item) => label(item) === "build box");
  expect(row?.querySelector(".acpmux-env-state")?.textContent).toBe(t("switch.failedShort"));
});

test("a machine that failed to start says so, not Not connected", async () => {
  await mount(true, { cloudMachines: [{ id: "vm-bad", name: "broken box", stage: "failed" }] });
  await openMachines();
  const row = pickerRows().find((item) => label(item) === "broken box");
  expect(row?.querySelector(".acpmux-env-state")?.textContent).toBe(t("switch.failedShort"));
});

test("a resume shows as starting at once, before the app's list comes back", async () => {
  const { runCloudMachine, setCloudMachinesForTest } = await import("../src/agent-session/acpmux/cloudMachines");
  setCloudMachinesForTest(account);
  let release!: () => void;
  const held = new Promise<void>((resolve) => (release = resolve));
  const call = async (method: string) => {
    if (method === "cloudMachine.resume") await held;
    return method === "cloudMachine.list" ? { signedIn: true, loaded: true, machines: account } : null;
  };
  await mount(true, {
    cloudMachines: undefined,
    onCloudMachine: (machine: CloudMachine) => void runCloudMachine(machine, call),
  });
  await openMachines();
  await act(async () =>
    pickerRows()
      .find((row) => label(row) === "build box")!
      .click(),
  );
  await openMachines();
  const row = pickerRows().find((item) => label(item) === "build box");
  expect(row?.querySelector(".acpmux-env-state")?.textContent).toBe(t("composer.envStarting"));
  await act(async () => {
    release();
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
});

test("previews off: the plain Computer menu lists them too, and a pick runs the machine's action", async () => {
  const picks = await mount(false);
  await openPicker();
  const items = [...doc().querySelectorAll<HTMLElement>(".acpmux-location-menu .acpmux-menu-item")].filter((item) =>
    item.querySelector(".acpmux-location-name"),
  );
  expect(items.map(label)).toEqual(["this-mac", "gpu-box", "build box", "eval box", "fresh box"]);
  const ready = items[3]!;
  expect(ready.querySelector(".acpmux-location-name")!.getAttribute("data-ready")).toBeNull();
  expect(ready.querySelector(".acpmux-menu-description")?.textContent).toBe(t("composer.envOpenMachine"));
  await act(async () => ready.click());
  expect(picks).toEqual([["cloud", "vm-ready"]]);
});

test("previews off: New Cloud Machine says what one gives, as the environment picker does", async () => {
  await mount(false);
  await openPicker();
  const create = [...doc().querySelectorAll<HTMLElement>(".acpmux-location-menu .acpmux-location-choose")].find(
    (item) => label(item) === t("composer.newCloudMachine"),
  );
  expect(create?.querySelector(".acpmux-menu-description")?.textContent).toBe(t("composer.newCloudMachineDetail"));
});

test("a started chat lists no account machine", async () => {
  await mount(true, { started: true, onOffload: () => undefined, offloads: ["move"] });
  await openPicker();
  expect(pickerRows().map(label)).not.toContain("build box");
});

test("an older chat's plain picker reads the Cloud account as it opens, so a signed-in person gets no sign-in row", async () => {
  const posted: { method: string; params: unknown }[] = [];
  answerAsTheApp(posted);
  // No `onProject`: not a new chat, so its machine list never reads the account's machines; the
  // connect rows still need the account state.
  await mount(false, { peers: [], onProject: undefined, cloudMachines: undefined });
  await openPicker();
  await act(async () => undefined);
  expect(posted.map((message) => message.method)).toContain("cloudMachine.list");
  const labels = [...doc().querySelectorAll<HTMLElement>(".acpmux-location-menu .acpmux-menu-item")].map(label);
  expect(labels).not.toContain("Sign in for Cloud");
});

function answerAsTheApp(
  posted: { method: string; params: unknown }[],
  listReply: () => unknown = () => ({ ok: true, value: { signedIn: true, loaded: true, machines: [account[0]] } }),
) {
  (dom.window as unknown as { webkit: unknown }).webkit = {
    messageHandlers: {
      agentSession: {
        postMessage: (message: { method: string; params: unknown }) => {
          posted.push(message);
          return message.method === "cloudMachine.list" ? listReply() : { ok: true, value: null };
        },
      },
    },
  };
}

test("by default the list is the app's, read as the machine list opens", async () => {
  const posted: { method: string; params: unknown }[] = [];
  answerAsTheApp(posted);
  // No list or pick handler of the test's own: the app's (cloudMachines.ts) answers.
  await mount(true, { cloudMachines: undefined, onCloudMachine: undefined });
  await openMachines();
  await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  expect(posted.map((message) => message.method)).toContain("cloudMachine.list");
  const paused = pickerRows().find((row) => label(row) === "build box");
  expect(paused, "the app's machine is listed").toBeTruthy();
  await act(async () => paused!.click());
  await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  expect(posted.find((message) => message.method === "cloudMachine.resume")?.params).toEqual({ id: "vm-paused" });
});

test("previews off: the plain Computer menu reads the app's list as it opens too", async () => {
  const posted: { method: string; params: unknown }[] = [];
  answerAsTheApp(posted);
  await mount(false, { cloudMachines: undefined, onCloudMachine: undefined });
  await openPicker();
  await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  expect(posted.map((message) => message.method)).toContain("cloudMachine.list");
  const labels = [...doc().querySelectorAll(".acpmux-location-menu .acpmux-menu-item")].map(label);
  expect(labels).toContain("build box");
});

test("a host an earlier Cloud chat ran on gives way to the account's machine of that name", async () => {
  const { withCloudMachines } = await import("../src/agent-session/acpmux/cloudMachines");
  const listed = [
    { id: "local", label: "this-mac", kind: "local" as const },
    { id: "gpu-box", label: "gpu-box", kind: "ssh" as const },
    { id: "build box", label: "build box", kind: "cloud" as const },
    { id: "eval box", label: "eval box", kind: "cloud" as const },
  ];
  const merged = withCloudMachines(listed, account, ["gpu-box"], "eval box");
  // build box was only an old chat's host: the account's row, which resumes it, takes its place.
  // eval box is the machine this chat is on: its row stays, and the account's is not added twice.
  // GPU-BOX is an acpmux peer: acpmux's row stays.
  expect(merged.map((row) => [row.label, "cloudMachine" in row])).toEqual([
    ["this-mac", false],
    ["gpu-box", false],
    ["eval box", false],
    ["build box", true],
    ["fresh box", true],
  ]);
});

test("previews on: a paused machine an earlier chat ran on resumes; it starts no chat", async () => {
  const picks = await mount(true, {
    sessions: [{ sessionId: "old", cwd: "/home/you/src", host: "build box", hostKind: "cloud", updatedAt: 0 }],
  });
  await openMachines();
  const rows = pickerRows().filter((row) => label(row) === "build box");
  expect(rows).toHaveLength(1);
  expect(rows[0]!.querySelector(".acpmux-env-state")?.textContent).toBe(t("composer.envPausedResume"));
  await act(async () => rows[0]!.click());
  expect(picks).toEqual([["cloud", "vm-paused"]]);
});
