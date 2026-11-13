// l10n-allow-file: machine names in fixtures.
// The machine card of a started chat on a Cloud machine (MachineCard.tsx): the location chip's
// popover opens on it, names the machine and its size, says Awake or Asleep with a dot (the chip
// carries the same dot), shows the last load and memory reading while awake, offers Wake machine
// while asleep, and lists where the chat can go under Continue on.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { translate as t } from "../src/agent-session/acpmux/i18n";
import type { CloudMachine } from "../src/agent-session/acpmux/cloudMachines";
import type { MachineResources } from "../src/agent-session/acpmux/machineResources";

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
let posted: { method: string; params: unknown }[] = [];
/// What the app's `cloudMachine.list` answers.
let listed: CloudMachine[] = [];

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

const SIZE = { cpu: 4, memoryMb: 16384, diskMb: 65536 };
const READING: MachineResources = {
  ramFreeGB: 12.9,
  load1: 0.4,
  coresBusy: 0,
  cores: 4,
  busy: false,
  lowMemory: false,
};

/// A started chat on the Cloud machine `box-1` (acpmux's peer of that name), with the account's
/// record of it at `stage`, and two places it can go: this Mac and another machine that is down.
async function mount({
  stage,
  connected,
  resources,
}: {
  stage?: string;
  connected: boolean;
  resources?: MachineResources;
}) {
  const { createRoot } = await import("react-dom/client");
  const { ComposerContext } = await import("../src/agent-session/acpmux/ComposerContext");
  const { setCloudMachinesForTest, setCloudMachinesForTestAccount } =
    await import("../src/agent-session/acpmux/cloudMachines");
  posted = [];
  (dom.window as unknown as { webkit: unknown }).webkit = {
    messageHandlers: {
      agentSession: {
        postMessage: (message: { method: string; params: unknown }) => {
          posted.push({ method: message.method, params: message.params });
          // The app's list after a Resume says the machine is on its way up.
          if (message.method === "cloudMachine.resume") listed = listed.map((row) => ({ ...row, stage: "booting" }));
          return Promise.resolve({
            ok: true,
            value: message.method === "cloudMachine.list" ? { signedIn: true, loaded: true, machines: listed } : {},
          });
        },
      },
    },
  };
  const machines: CloudMachine[] = stage ? [{ id: "vm-1", name: "box-1", stage, size: SIZE }] : [];
  listed = machines;
  setCloudMachinesForTest(machines);
  setCloudMachinesForTestAccount(true);
  const moved: string[] = [];
  const props = {
    environments: true,
    started: true,
    onProject: undefined,
    summary: {
      sessionId: "s",
      harness: "claude",
      host: "box-1",
      peer: "box-1",
      hostKind: "cloud",
      cwd: "/home/you/app",
    },
    sessions: [],
    peers: ["box-1"],
    peerKinds: { "box-1": "cloud" },
    peerConnected: { "box-1": connected },
    peerStates: { "box-1": connected ? "connected" : "offline" },
    ...(resources ? { peerResources: { "box-1": resources } } : {}),
    localName: "this-mac",
    offloads: ["bringBack"],
    onOffload: () => undefined,
    moveTargets: [
      { id: "local", label: "", kind: "local" },
      { id: "vm-2", label: "other-box", kind: "cloud", reason: "Device offline" },
    ],
    onMoveTo: (id: string) => moved.push(id),
    stripLayout: "combined",
  } as unknown as Parameters<typeof ComposerContext>[0];
  root = createRoot(host);
  await act(async () => root!.render(<ComposerContext {...props} />));
  return { moved };
}

const doc = () => dom.window.document;
const chip = () =>
  [...host.querySelectorAll<HTMLButtonElement>(".acpmux-location-button")].find((button) =>
    (button.getAttribute("aria-label") ?? "").startsWith(t("composer.environment") + ":"),
  );
async function open() {
  const button = chip();
  expect(button, "no location chip").toBeTruthy();
  await act(async () => {
    button!.dispatchEvent(new dom.window.MouseEvent("pointerdown", { bubbles: true }));
    button!.click();
  });
}
const card = () => doc().querySelector<HTMLElement>(".acpmux-env-popover .acpmux-machine-card");
const text = (selector: string) => card()?.querySelector(selector)?.textContent?.replace(/\s+/g, " ").trim();
const rows = () => [...doc().querySelectorAll<HTMLElement>(".acpmux-env-popover .acpmux-menu-item")];
const label = (row: HTMLElement) => row.querySelector(".acpmux-menu-label")?.textContent;
const chipDot = () => chip()?.querySelector<HTMLElement>(".acpmux-env-live");

test("awake: the card names the machine, its size and Awake, its load and memory, then Continue on", async () => {
  const { moved } = await mount({ stage: "ready", connected: true, resources: READING });
  expect(chipDot()?.getAttribute("data-connected")).toBe("true");
  expect(chipDot()?.textContent).toBe(t("machineCard.awake"));
  await open();
  expect(text(".acpmux-machine-card-name")).toBe("box-1");
  expect(text(".acpmux-machine-card-specs")).toBe(
    [
      t("machineCard.specCpu", { n: "4" }),
      t("machineCard.specMemory", { n: "16" }),
      t("machineCard.specDisk", { n: "64" }),
    ].join(" · "),
  );
  expect(text(".acpmux-machine-card-status")).toBe(t("machineCard.awake"));
  const values = [...card()!.querySelectorAll(".acpmux-plan-usage-value")].map((value) => value.textContent);
  expect(values).toEqual([
    t("machineCard.loadValue", { load: "0.4", cores: "4" }),
    t("machineCard.memoryFreeOf", { free: "12", total: "16" }),
  ]);
  const bars = [...card()!.querySelectorAll<HTMLProgressElement>("progress")].map((bar) => bar.getAttribute("value"));
  expect(bars).toEqual(["10", "25"]);
  // No Wake machine while awake: Continue on is the whole list, a down machine greyed with why.
  expect(rows().map(label)).toEqual([t("composer.thisMac"), "other-box"]);
  expect(rows()[0]!.querySelector(".acpmux-env-row")?.getAttribute("data-card-section")).toBe(
    t("machineCard.continueOn"),
  );
  const down = rows()[1]!;
  expect(down.querySelector(".acpmux-menu-description")?.textContent).toBe("Device offline");
  await act(async () => down.click());
  expect(moved).toEqual([]);
  await act(async () => rows()[0]!.click());
  expect(moved).toEqual(["local"]);
});

test("asleep: Asleep with a grey dot, no usage, and Wake machine runs the app's Resume", async () => {
  await mount({ stage: "paused", connected: false, resources: READING });
  expect(chipDot()?.getAttribute("data-sleep")).toBe("paused");
  expect(chipDot()?.textContent).toBe(t("machineCard.asleep"));
  await open();
  expect(text(".acpmux-machine-card-status")).toBe(t("machineCard.asleep"));
  expect(card()?.getAttribute("data-status")).toBe("paused");
  // A reading from before it slept would be stale: none is shown.
  expect(card()?.querySelector(".acpmux-plan-usage-rows")).toBeNull();
  expect(card()?.querySelector(".acpmux-machine-card-note")).toBeNull();
  expect(rows().map(label)).toEqual([t("machineCard.wake"), t("composer.thisMac"), "other-box"]);
  // Continue on heads the first place to go, under the hairline, below Wake machine.
  expect(rows()[1]!.querySelector(".acpmux-env-row")?.getAttribute("data-divider")).toBe("");
  await act(async () => rows()[0]!.click());
  expect(posted.find((message) => message.method === "cloudMachine.resume")?.params).toEqual({ id: "vm-1" });
  expect(doc().querySelector(".acpmux-env-popover")).toBeNull();
  // It shows as waking at once (runCloudMachine), on the chip and in the card.
  expect(chipDot()?.getAttribute("data-sleep")).toBe("resuming");
  await open();
  expect(text(".acpmux-machine-card-status")).toBe(t("machineCard.waking"));
  expect(rows().map(label)).toEqual([t("composer.thisMac"), "other-box"]);
});

test("waking: the spinner in the dot's place, Waking, no usage and no Wake machine", async () => {
  await mount({ stage: "booting", connected: false });
  expect(chipDot()?.getAttribute("data-sleep")).toBe("resuming");
  await open();
  expect(text(".acpmux-machine-card-status")).toBe(t("machineCard.waking"));
  expect(card()?.querySelector(".acpmux-machine-card-spinner")).not.toBeNull();
  expect(card()?.querySelector(".acpmux-plan-usage-rows")).toBeNull();
  expect(rows().map(label)).toEqual([t("composer.thisMac"), "other-box"]);
});

test("failed: Failed, no usage, no Wake machine", async () => {
  await mount({ stage: "failed", connected: false });
  await open();
  expect(text(".acpmux-machine-card-status")).toBe(t("machineCard.failed"));
  expect(card()?.querySelector(".acpmux-plan-usage-rows")).toBeNull();
  expect(rows().map(label)).toEqual([t("composer.thisMac"), "other-box"]);
});

test("awake with no reading yet: says so, never a zero", async () => {
  await mount({ stage: "ready", connected: true });
  await open();
  expect(card()?.querySelector(".acpmux-plan-usage-rows")).toBeNull();
  expect(text(".acpmux-machine-card-note")).toBe(t("machineCard.usageUnread"));
});

test("no account record: acpmux's link says awake, and the card has no size", async () => {
  await mount({ connected: true, resources: READING });
  await open();
  expect(text(".acpmux-machine-card-status")).toBe(t("machineCard.awake"));
  expect(card()?.querySelector(".acpmux-machine-card-specs")).toBeNull();
  // Free memory alone, with no bar: the total is the size, which nothing said.
  const memory = [...card()!.querySelectorAll(".acpmux-plan-usage-value")].map((value) => value.textContent)[1];
  expect(memory).toBe(t("machineCard.memoryFree", { free: "12" }));
  expect(card()!.querySelectorAll("progress")).toHaveLength(1);
});

test("Escape closes the popover", async () => {
  await mount({ stage: "paused", connected: false });
  await open();
  const field = doc().querySelector<HTMLInputElement>(".acpmux-env-popover input");
  expect(field).not.toBeNull();
  await act(async () => {
    field!.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }));
  });
  expect(doc().querySelector(".acpmux-env-popover")).toBeNull();
  expect(posted.some((message) => message.method === "cloudMachine.resume")).toBe(false);
});
