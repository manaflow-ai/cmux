// The server card page's Add Device card (cmux-page://cmux.server-cards/#/add-device) over a fake
// host: it opens on the way the status asks for, mints only on Make Line, shows the line and copies
// it through the host without ever sending the line back, reads `joined` on a mesh change and flips,
// hands off without closing the panel itself, closes on Cancel and Escape, and starts over on a new
// opening.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import type { PageClient } from "../src/pages/shared/pageClient";
import { createStrings } from "../src/pages/shared/i18n";
import table from "../src/pages/server-cards/generated/strings.json";
import type { AddDeviceStatus } from "../src/pages/server-cards/addDevice/types";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "location",
  "HTMLElement",
  "HTMLButtonElement",
  "HTMLInputElement",
  "Node",
  "Element",
  "MutationObserver",
  "getComputedStyle",
  "KeyboardEvent",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>", { url: "https://cmux.test/#/add-device" });
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    location: window.location,
    HTMLElement: window.HTMLElement,
    HTMLButtonElement: window.HTMLButtonElement,
    HTMLInputElement: window.HTMLInputElement,
    Node: window.Node,
    Element: window.Element,
    MutationObserver: window.MutationObserver,
    getComputedStyle: window.getComputedStyle.bind(window),
    KeyboardEvent: window.KeyboardEvent,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = window.document.getElementById("root")!;
});

afterAll(() => {
  act(() => root?.unmount());
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

type Call = { op: string; params: unknown };
const SECRET = " curl -fsSL https://cmux.example/v1/machines/join.sh | CMUX_JOIN=cmj_TESTTOKEN sh";

function fakeHost(initial: Partial<AddDeviceStatus> = {}) {
  let status: AddDeviceStatus = { session: 1, open: true, way: null, join: true, invite: false, ...initial };
  let joined: { id: string; name: string } | null = null;
  const calls: Call[] = [];
  const emitters: Record<string, (data: unknown) => void> = {};
  const client: PageClient = {
    call: async <R,>(op: string, params: unknown) => {
      calls.push({ op, params });
      switch (op) {
        case "cmux.addDevice.status":
          return status as R;
        case "cmux.addDevice.list":
          return {
            network: { kind: "tailscale", up: true },
            available: [{ name: "studio", address: "studio.ts.net", os: "macOS", mine: true, fromSSHConfig: false }],
          } as R;
        case "cmux.addDevice.mint":
          return { line: { line: SECRET, joinTokenId: "jt_1", expiresAt: Date.now() + 600_000 } } as R;
        case "cmux.addDevice.joined":
          return joined as R;
        case "cmux.addDevice.doctor":
          return [{ step: "heartbeat", title: "Check in with cmux", state: "ok", detail: "" }] as R;
        default:
          return null as R;
      }
    },
    subscribe: async <E,>(stream: string, onEvent: (data: E, seq: number) => void) => {
      emitters[stream] = (data) => onEvent(data as E, 1);
      return () => {};
    },
    handle: () => () => {},
  };
  return {
    client,
    calls,
    set: (next: Partial<AddDeviceStatus>) => void (status = { ...status, ...next }),
    join: (machine: { id: string; name: string }) => void (joined = machine),
    emit: (stream: string, data: unknown = {}) => emitters[stream]?.(data),
  };
}

async function flush() {
  for (let i = 0; i < 6; i++) await act(async () => {});
}

async function mount(fake: ReturnType<typeof fakeHost>) {
  const { ServerCardsPage } = await import("../src/pages/server-cards/ServerCardsPage");
  act(() => root?.unmount());
  root = createRoot(host);
  act(() => root!.render(<ServerCardsPage client={fake.client} strings={createStrings(table, ["en"])} />));
  await flush();
}

const card = () => host.querySelector("[data-card='add-device']")!;
const ops = (calls: Call[], op: string) => calls.filter((call) => call.op === op);
const press = async (selector: string) => {
  act(() => (host.querySelector(selector) as HTMLButtonElement).click());
  await flush();
};

test("opens on the pair code, mints only on Make Line, and copies through the host without the line", async () => {
  const fake = fakeHost();
  await mount(fake);
  expect(card().getAttribute("data-way")).toBe("joinLine");
  expect(card().getAttribute("data-join")).toBe("idle");
  expect(ops(fake.calls, "cmux.addDevice.mint")).toEqual([]);
  expect(host.textContent).toContain("Add a Device");
  await press("[data-action='makeJoinLine']");
  expect(ops(fake.calls, "cmux.addDevice.mint").map((call) => call.params)).toEqual([{ name: null }]);
  expect(card().getAttribute("data-join")).toBe("showing");
  expect(host.querySelector("[data-testid='add-device-join-line']")?.textContent).toBe(SECRET);
  expect(host.querySelector("[data-testid='add-device-countdown']")?.textContent).toMatch(/^Expires in (10:00|9:5\d)$/);
  await press("[data-action='copyJoinLine']");
  expect(ops(fake.calls, "cmux.addDevice.copyJoinLine").map((call) => call.params)).toEqual([{}]);
  expect(host.querySelector("[data-action='copyJoinLine']")?.textContent).toContain("Copied");
  // The secret never goes back to the host in any call.
  expect(fake.calls.some((call) => JSON.stringify(call.params).includes("cmj_"))).toBe(false);
});

test("a mesh change reads the list once and flips to joined with its checks", async () => {
  const fake = fakeHost();
  await mount(fake);
  await press("[data-action='makeJoinLine']");
  const reads = ops(fake.calls, "cmux.addDevice.joined").length;
  fake.join({ id: "m_1", name: "lane-vm-3" });
  await act(async () => fake.emit("cmux.addDevice.changes", { kind: "mesh" }));
  await flush();
  expect(ops(fake.calls, "cmux.addDevice.joined").length).toBe(reads + 1);
  expect(card().getAttribute("data-join")).toBe("joined");
  expect(host.textContent).toContain("lane-vm-3 joined");
  expect(host.textContent).toContain("Check in with cmux");
  expect(
    [...host.querySelectorAll(".server-card-footer [data-action]")].map((b) => b.getAttribute("data-action")),
  ).toEqual(["showMachines", "done"]);
});

test("a hand-off asks the host and leaves the panel to it; Cancel and Escape close the card", async () => {
  const fake = fakeHost({ way: "code" });
  await mount(fake);
  expect(card().getAttribute("data-way")).toBe("code");
  await press("[data-action='enterCode']");
  expect(ops(fake.calls, "cmux.addDevice.enterCode")).toHaveLength(1);
  expect(ops(fake.calls, "cmux.card.close")).toEqual([]);
  await press("[data-action='cancel']");
  await act(async () => void document.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true })));
  await act(async () => fake.emit("cmux.card.commands", { command: "cancel" }));
  expect(ops(fake.calls, "cmux.card.close").map((call) => call.params)).toEqual([
    { card: "add-device" },
    { card: "add-device" },
    { card: "add-device" },
  ]);
});

test("Advanced shows the ssh way's computers; a new opening starts over on its way", async () => {
  const fake = fakeHost();
  await mount(fake);
  await press("[data-action='toggleAdvanced']");
  expect(card().getAttribute("data-way")).toBe("network");
  expect(host.textContent).toContain("signs in with a key");
  fake.set({ session: 2, way: "newDevice" });
  await act(async () => fake.emit("cmux.addDevice.changes", { kind: "opened" }));
  await flush();
  expect(card().getAttribute("data-way")).toBe("newDevice");
  expect(host.querySelector("[data-testid='add-device-setup-line']")?.textContent).toContain("install-static.sh");
});
