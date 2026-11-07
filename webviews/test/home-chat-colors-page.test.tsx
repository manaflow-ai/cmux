// The Chat Colors page draws only what its host last sent, and every call names its session:
// a pick is sent to the host (not drawn), a state for another chat is dropped, a state that arrives
// before its session draws once the session does, and Escape and Return close the panel.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "Element",
  "customElements",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>");
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    Element: window.Element,
    customElements: window.customElements,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = window.document.getElementById("root")!;
});

afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const preview = {
  background: "#FFFFFF",
  sent: { fill: "#0284FE", text: "#FFFFFF" },
  received: { fill: "#E9E9EB", text: "#000000" },
};

async function mount() {
  const { mountChatColors } = await import("../src/pages/home-chat-colors/mount");
  const { ChatColorsOps } = await import("../src/pages/home-chat-colors/host");
  const calls: Array<{ op: string; params: Record<string, unknown> }> = [];
  const streams = new Map<string, (data: unknown) => void>();
  const client = {
    call: (op: string, params: Record<string, unknown>) => {
      calls.push({ op, params });
      return Promise.resolve(null);
    },
    subscribe: async (stream: string, onEvent: (data: unknown) => void) => {
      streams.set(stream, onEvent);
      return () => {};
    },
    handle: () => () => {},
  };
  // A fresh container per mount: each mount makes its own React root.
  const container = host.ownerDocument.createElement("div");
  host.replaceChildren(container);
  const page = mountChatColors(container, client as never);
  await act(async () => {});
  const emit = (stream: string, data: unknown) => act(async () => streams.get(stream)!(data));
  return { page, calls, emit, ops: ChatColorsOps };
}

const reset = () =>
  [...host.querySelectorAll<HTMLButtonElement>("button")].find((button) => button.textContent === "Reset to Default")!;
const rows = () => [...host.querySelectorAll(".cc-row")];

test("a pick is sent with its session and drawn only when the host's state comes back", async () => {
  const { calls, emit, ops } = await mount();
  await emit(ops.session, { id: "s1", conversation: "chat", name: "Ada" });
  await emit(ops.state, { session: "s1", colors: {}, preview });
  const green = rows()[0]!.querySelector<HTMLButtonElement>('[data-color="#34C759"]')!;
  expect(green.getAttribute("aria-pressed")).toBe("false");
  expect(reset().disabled).toBe(true);
  await act(async () => green.click());
  expect(calls).toEqual([{ op: ops.set, params: { session: "s1", role: "sent", color: "#34C759" } }]);
  expect(green.getAttribute("aria-pressed")).toBe("false");
  // The CLI (or the pick) changed the store: the host streams the new state.
  await emit(ops.state, { session: "s1", colors: { sent: "#34C759" }, preview });
  expect(green.getAttribute("aria-pressed")).toBe("true");
  expect(reset().disabled).toBe(false);
});

test("another chat's state is dropped, and a state sent before its session draws with it", async () => {
  const { page, emit, ops } = await mount();
  await emit(ops.session, { id: "s1", conversation: "a", name: "A" });
  await emit(ops.state, { session: "s1", colors: { received: "#1C2A4A" }, preview });
  await emit(ops.state, { session: "s2", colors: { received: "#E9E9EB" }, preview });
  expect(page.state()?.colors.received).toBe("#1C2A4A");
  await emit(ops.session, { id: "s2", conversation: "b", name: "B" });
  expect(page.state()?.colors.received).toBe("#E9E9EB");
});

test("Default, Custom Color, Reset, Escape and Return call the host", async () => {
  const { calls, emit, ops } = await mount();
  await emit(ops.session, { id: "s1", conversation: "chat", name: "" });
  await emit(ops.state, { session: "s1", colors: { sentText: "#000000" }, preview });
  const textRow = rows()[1]!;
  await act(async () => textRow.querySelector<HTMLButtonElement>('button[aria-label^="Automatic"]')!.click());
  await act(async () => textRow.querySelector<HTMLButtonElement>('button[aria-label="Custom Color"]')!.click());
  await act(async () => reset().click());
  const view = host.ownerDocument.defaultView!;
  await act(async () => {
    host.ownerDocument.dispatchEvent(new view.KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
    host.ownerDocument.body.dispatchEvent(new view.KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
  });
  expect(calls.map((call) => [call.op, call.params])).toEqual([
    [ops.set, { session: "s1", role: "sentText", color: null }],
    [ops.customColor, { session: "s1", role: "sentText" }],
    [ops.reset, { session: "s1" }],
    [ops.done, { session: "s1" }],
    [ops.done, { session: "s1" }],
  ]);
});

test("a stored colour keeps its alpha and matches no opaque swatch", async () => {
  const { normalizeHex } = await import("../src/pages/home-chat-colors/host");
  expect(normalizeHex("#34c75980")).toBe("#34C75980");
  expect(normalizeHex("#34C759FF")).toBe("#34C759");
  expect(normalizeHex("#fff")).toBe("#FFFFFF");
  expect(normalizeHex("blue")).toBeNull();
  const { emit, ops } = await mount();
  await emit(ops.session, { id: "s1", conversation: "chat", name: "" });
  await emit(ops.state, { session: "s1", colors: { sent: "#34C75980" }, preview });
  const row = rows()[0]!;
  expect(row.querySelector('[data-color="#34C759"]')!.getAttribute("aria-pressed")).toBe("false");
  expect(row.querySelector('button[aria-label="Default"]')!.getAttribute("aria-pressed")).toBe("false");
  expect(row.querySelector<HTMLElement>(".cc-well")!.style.getPropertyValue("--cc-well")).toBe("#34C75980");
});
