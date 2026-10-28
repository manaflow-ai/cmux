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
const label = (row: Element) => row.querySelector(".acpmux-menu-label")?.textContent;
const pickerRows = () =>
  [...doc().querySelectorAll<HTMLElement>(".acpmux-env-popover .acpmux-menu-item")].filter((row) =>
    row.querySelector(".acpmux-env-row:not(.acpmux-env-new)"),
  );

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

test("previews on: the account's machines join Cloud and VMs with their stage, a pick but no ⌥⌘ digit", async () => {
  const picks = await mount(true);
  await openPicker();
  const rows = pickerRows();
  expect(rows.map(label)).toEqual(["this-mac", "gpu-box", "build box", "eval box", "fresh box"]);
  const cloud = rows.slice(2);
  expect(cloud.map((row) => row.querySelector(".acpmux-env-state")?.textContent)).toEqual([
    t("composer.envPausedResume"),
    t("composer.envOpenMachine"),
    t("composer.envStarting"),
  ]);
  expect(cloud[0]!.querySelector(".acpmux-env-row")!.getAttribute("data-section")).toBe(t("composer.envFleet"));
  expect(cloud.some((row) => row.querySelector('[data-ready="false"], [aria-disabled="true"], .acpmux-env-key'))).toBe(
    false,
  );
  await act(async () => cloud[0]!.click());
  expect(picks).toEqual([["cloud", "vm-paused"]]);
  // No chat moved: the composer still names this Mac.
  expect(computerButton()?.getAttribute("aria-label")).toBe(`${t("composer.environment")}: this-mac`);
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

test("a started chat lists no account machine", async () => {
  await mount(true, { started: true, onOffload: () => undefined, offloads: ["move"] });
  await openPicker();
  expect(pickerRows().map(label)).not.toContain("build box");
});

function answerAsTheApp(posted: { method: string; params: unknown }[]) {
  (dom.window as unknown as { webkit: unknown }).webkit = {
    messageHandlers: {
      agentSession: {
        postMessage: (message: { method: string; params: unknown }) => {
          posted.push(message);
          return message.method === "cloudMachine.list"
            ? { ok: true, value: { signedIn: true, loaded: true, machines: [account[0]] } }
            : { ok: true, value: null };
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
  await openPicker();
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
  await openPicker();
  const rows = pickerRows().filter((row) => label(row) === "build box");
  expect(rows).toHaveLength(1);
  expect(rows[0]!.querySelector(".acpmux-env-state")?.textContent).toBe(t("composer.envPausedResume"));
  await act(async () => rows[0]!.click());
  expect(picks).toEqual([["cloud", "vm-paused"]]);
});
