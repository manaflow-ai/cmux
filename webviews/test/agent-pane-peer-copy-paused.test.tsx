// l10n-allow-file: test fixture machine names, not shipped UI.
//
// A chat on a paused Cloud machine (cmuxterm-hq#4755: "a paused machine's chat reads 'offline'.
// There is no Resume in the pane"). The banner over the Mac's copy of the chat reads the account's
// machine of the chat's peer name (`cloudMachine.list`, any case) and:
//
//   - says a paused machine is paused and offers Resume, which runs `cloudMachine.resume` once and
//     reads the list again;
//   - spins while the machine starts (after Resume, or a stage on the way up), reading the list
//     every few seconds, and stops reading once it no longer starts or the banner goes;
//   - says "offline" as before for a machine the account does not list, or one that is ready;
//   - puts Resume where each arm of `paused-machine-resume` says, the actions row by default.
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
  "Element",
  "Node",
  "MouseEvent",
  "Event",
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
    Element: dom.window.Element,
    Node: dom.window.Node,
    MouseEvent: dom.window.MouseEvent,
    Event: dom.window.Event,
  });
  host = dom.window.document.getElementById("root")!;
});

afterEach(async () => {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
  delete globalThis.cmuxExperiments;
  (await import("../src/agent-session/acpmux/cloudMachines")).setCloudMachinesForTest([]);
});

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const PEER = "dev-vm-2";
const paused: CloudMachine = { id: "vm_paused", name: "DEV-VM-2", stage: "paused" };

/// The app's side of `cloudMachine.*`: each list read answers `machines()`, and Resume moves the
/// machine to `booting`.
function fakeApp(start: CloudMachine[]) {
  let machines = start;
  const calls: [string, unknown][] = [];
  const call = async (method: string, params?: Record<string, unknown>) => {
    calls.push([method, params]);
    if (method === "cloudMachine.list") return { signedIn: true, loaded: true, machines };
    if (method === "cloudMachine.resume")
      machines = machines.map((m) => (m.id === params?.id ? { ...m, stage: "booting" } : m));
    return {};
  };
  return { call, calls, set: (next: CloudMachine[]) => (machines = next) };
}

async function mount(
  peer: string | undefined,
  call: (method: string, params?: Record<string, unknown>) => Promise<unknown>,
  onReconnect?: (peer: string) => Promise<unknown>,
) {
  const { createRoot } = await import("react-dom/client");
  const { PeerCopyBanner } = await import("../src/agent-session/acpmux/PeerCopyBanner");
  const { usePeerCloudMachine } = await import("../src/agent-session/acpmux/peerCloudMachine");
  function Host({ peer }: { peer: string | undefined }) {
    const machine = usePeerCloudMachine(peer, call);
    return peer ? (
      <PeerCopyBanner
        copy={{ peer, offline: true }}
        machine={machine.state}
        onResume={machine.resume}
        onReconnect={onReconnect}
      />
    ) : null;
  }
  root ??= createRoot(host);
  await act(async () => root!.render(<Host peer={peer} />));
  // The list read the banner asked for answers.
  await act(async () => await new Promise((resolve) => setImmediate(resolve)));
}

const banner = () => host.querySelector<HTMLElement>(".acpmux-peer-copy");
const resumeButton = () =>
  [...host.querySelectorAll<HTMLButtonElement>("button")].find((b) => b.textContent === t("peerCopy.paused.resume"));
const reads = (calls: [string, unknown][]) => calls.filter(([method]) => method === "cloudMachine.list").length;

test("a paused machine's chat says it is paused and Resume starts it once", async () => {
  const app = fakeApp([paused, { id: "vm_other", name: "other", stage: "ready" }]);
  await mount(PEER, app.call);
  expect(banner()?.dataset.machine).toBe("paused");
  expect(banner()?.textContent).toContain(t("peerCopy.paused.title", { machine: PEER }));
  expect(banner()?.textContent).not.toContain(t("peerCopy.offline.title", { machine: PEER }));
  // The default arm: Resume in the actions row under the text, as the other banners put theirs.
  expect(banner()?.dataset.arm).toBe("actions");
  expect(resumeButton()?.closest(".acpmux-live-chat-actions")).toBeTruthy();
  await act(async () => {
    resumeButton()!.click();
    await new Promise((resolve) => setImmediate(resolve));
  });
  expect(app.calls.filter(([method]) => method === "cloudMachine.resume")).toEqual([
    ["cloudMachine.resume", { id: "vm_paused" }],
  ]);
  // The list read after it says booting: the banner spins, with no Resume to click twice.
  expect(banner()?.dataset.machine).toBe("starting");
  expect(banner()?.textContent).toContain(t("peerCopy.starting.title", { machine: PEER }));
  expect(banner()?.querySelector(".cv-spinner")).toBeTruthy();
  expect(resumeButton()).toBeUndefined();
});

test("a starting machine is read again until it leaves the starting stages, and no read outlives the banner", async () => {
  const { STARTING_READ_MS } = await import("../src/agent-session/acpmux/peerCloudMachine");
  const app = fakeApp([{ ...paused, stage: "booting" }]);
  const timers: { fn: () => void; ms?: number }[] = [];
  const cleared: unknown[] = [];
  const realSet = globalThis.setInterval;
  const realClear = globalThis.clearInterval;
  globalThis.setInterval = ((fn: () => void, ms?: number) => (
    timers.push({ fn, ms }),
    timers.length
  )) as typeof setInterval;
  globalThis.clearInterval = ((id: unknown) => void cleared.push(id)) as typeof clearInterval;
  try {
    await mount(PEER, app.call);
    expect(banner()?.dataset.machine).toBe("starting");
    expect(timers.map((timer) => timer.ms)).toEqual([STARTING_READ_MS]);
    const before = reads(app.calls);
    app.set([{ ...paused, stage: "connecting" }]);
    await act(async () => {
      timers[0]!.fn();
      await new Promise((resolve) => setImmediate(resolve));
    });
    expect(reads(app.calls)).toBe(before + 1);
    // Ready but its chat not back yet: no longer starting, so the reads stop.
    app.set([{ ...paused, stage: "ready" }]);
    await act(async () => {
      timers[0]!.fn();
      await new Promise((resolve) => setImmediate(resolve));
    });
    expect(banner()?.dataset.machine).toBeUndefined();
    expect(cleared).toEqual([1]);
    expect(timers.length).toBe(1);
    // Leaving the starting stages asks for no read of its own.
    expect(reads(app.calls)).toBe(before + 2);
    // The chat's machine answers again: the banner goes and nothing more is read.
    const after = reads(app.calls);
    await mount(undefined, app.call);
    expect(banner()).toBeNull();
    expect(reads(app.calls)).toBe(after);
  } finally {
    globalThis.setInterval = realSet;
    globalThis.clearInterval = realClear;
  }
});

test("a machine stuck starting is read at most STARTING_READS times", async () => {
  const { STARTING_READS } = await import("../src/agent-session/acpmux/peerCloudMachine");
  const app = fakeApp([{ ...paused, stage: "booting" }]);
  const timers: (() => void)[] = [];
  const cleared: unknown[] = [];
  const realSet = globalThis.setInterval;
  const realClear = globalThis.clearInterval;
  globalThis.setInterval = ((fn: () => void) => (timers.push(fn), timers.length)) as typeof setInterval;
  globalThis.clearInterval = ((id: unknown) => void cleared.push(id)) as typeof clearInterval;
  try {
    await mount(PEER, app.call);
    const before = reads(app.calls);
    // Each tick's read answers before the next (a read in flight is shared, not repeated).
    for (let i = 0; i < STARTING_READS; i++)
      await act(async () => {
        timers[0]!();
        await new Promise((resolve) => setImmediate(resolve));
      });
    expect(reads(app.calls)).toBe(before + STARTING_READS);
    expect(cleared).toContain(1);
    // Still starting, as far as the list knows: the banner keeps saying so, with no Resume.
    expect(banner()?.dataset.machine).toBe("starting");
    expect(timers.length).toBe(1);
  } finally {
    globalThis.setInterval = realSet;
    globalThis.clearInterval = realClear;
  }
});

test("a Resume still running for one machine never makes another read as starting", async () => {
  const other: CloudMachine = { id: "vm_b", name: "build-box", stage: "paused" };
  const app = fakeApp([paused, other]);
  // The app never answers this Resume.
  const call = (method: string, params?: Record<string, unknown>) =>
    method === "cloudMachine.resume" ? new Promise<unknown>(() => undefined) : app.call(method, params);
  await mount(PEER, call);
  await act(async () => {
    resumeButton()!.click();
    await new Promise((resolve) => setImmediate(resolve));
  });
  expect(banner()?.dataset.machine).toBe("starting");
  await mount("build-box", call);
  expect(banner()?.dataset.machine).toBe("paused");
  expect(resumeButton()).toBeTruthy();
});

test("a name two of the account's machines share reads offline, with no Resume", async () => {
  const app = fakeApp([paused, { id: "vm_twin", name: "dev-vm-2", stage: "paused" }]);
  await mount(PEER, app.call);
  expect(banner()?.dataset.machine).toBeUndefined();
  expect(resumeButton()).toBeUndefined();
  const { peerCloudMachine } = await import("../src/agent-session/acpmux/peerCloudMachine");
  expect(peerCloudMachine([paused], PEER)?.id).toBe("vm_paused");
  expect(peerCloudMachine([paused, { ...paused, id: "vm_twin" }], PEER)).toBeUndefined();
});

test("offline peer Reconnect invokes doctor and shows its refusal", async () => {
  const app = fakeApp([]);
  const calls: string[] = [];
  await mount(PEER, app.call, async (peer) => {
    calls.push(peer);
    throw new Error("peer_unreachable: refused by doctor");
  });
  const reconnect = [...host.querySelectorAll<HTMLButtonElement>("button")].find(
    (button) => button.textContent === t("sessionInfo.connectors.reconnectAction"),
  );
  expect(reconnect).toBeTruthy();
  await act(async () => {
    reconnect!.click();
    await new Promise((resolve) => setImmediate(resolve));
  });
  expect(calls).toEqual([PEER]);
  expect(host.querySelector('[role="alert"]')?.textContent).toContain("peer_unreachable: refused by doctor");
  expect(host.querySelector<HTMLButtonElement>('button[data-state="failed"]')?.textContent).toBe(
    t("sessionInfo.connectors.retry"),
  );
});

test("a machine the account does not list, or one that is ready, reads offline as before", async () => {
  for (const machines of [[], [{ id: "vm_x", name: "elsewhere", stage: "paused" }], [{ ...paused, stage: "ready" }]]) {
    const app = fakeApp(machines);
    await mount(PEER, app.call);
    expect(banner()?.textContent).toContain(t("peerCopy.offline.title", { machine: PEER }));
    expect(resumeButton()).toBeUndefined();
    expect(reads(app.calls)).toBe(1);
    act(() => root?.unmount());
    root = undefined;
    (await import("../src/agent-session/acpmux/cloudMachines")).setCloudMachinesForTest([]);
  }
});

test("each arm of paused-machine-resume puts Resume where it says", async () => {
  for (const [arm, inTitle, className] of [
    ["inline", true, "acpmux-folder-choice-button"],
    ["button", true, "acpmux-peer-copy-resume"],
    ["actions", false, "acpmux-folder-choice-button"],
  ] as const) {
    globalThis.cmuxExperiments = { "paused-machine-resume": arm };
    const app = fakeApp([paused]);
    await mount(PEER, app.call);
    expect(banner()?.dataset.arm).toBe(arm);
    expect(!!resumeButton()?.closest(".acpmux-peer-copy-title")).toBe(inTitle);
    expect(resumeButton()?.className).toBe(className);
    act(() => root?.unmount());
    root = undefined;
    (await import("../src/agent-session/acpmux/cloudMachines")).setCloudMachinesForTest([]);
  }
});
