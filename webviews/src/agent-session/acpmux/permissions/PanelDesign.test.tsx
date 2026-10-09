import { afterAll, afterEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { PermissionPanel } from "./Panel";
import type { PermissionClientState, PermissionGroup } from "./protocol";

// Lawrence 2026-10-09 ("this ui is ugly"): the permission card says what it asks in one look, has one
// primary action, keeps shortcuts out of the labels, has one disclosure, and keeps its policy and
// isolation notes inside the card.
const dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true });
const globals = globalThis as Record<string, unknown>;
const saved = Object.fromEntries(
  ["window", "document", "HTMLElement", "HTMLDivElement", "IS_REACT_ACT_ENVIRONMENT"].map((key) => [key, globals[key]]),
);
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  HTMLElement: dom.window.HTMLElement,
  HTMLDivElement: dom.window.HTMLDivElement,
  IS_REACT_ACT_ENVIRONMENT: true,
});
afterAll(() => Object.assign(globals, saved));

const doc = dom.window.document;
const one: PermissionGroup = {
  groupId: "g",
  sessionId: "s",
  turnId: "t",
  revision: 1,
  state: "pending",
  decision: null,
  decisions: ["allow_once", "allow_chat", "deny"],
  items: [
    {
      permissionId: "p",
      state: "pending",
      request: {
        toolCall: { title: "cmux harness guide", kind: "execute", rawInput: { command: "cmux harness guide" } },
      },
    },
  ],
};
const state = (groups: PermissionGroup[] = [one]): PermissionClientState => ({
  supported: true,
  ready: true,
  groups,
  chatAllowance: false,
  loading: false,
  busy: false,
});

let root: Root | undefined;
afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
});
async function render(value = state()) {
  root = createRoot(doc.getElementById("root")!);
  await act(async () =>
    root!.render(
      createElement(PermissionPanel, {
        state: value,
        onRespond: () => {},
        onRetry: () => {},
        onRevoke: () => {},
        onRefresh: () => {},
      }),
    ),
  );
  return doc.querySelector<HTMLElement>("[data-permission-card]")!;
}

test("one request: the title asks to run the command, shown as code", async () => {
  const card = await render();
  const title = card.querySelector("[data-permission-title]")!;
  expect(title.textContent).toBe("Run cmux harness guide?");
  expect(title.querySelector("code")?.textContent).toBe("cmux harness guide");
});

test("exactly one primary action, Allow once; shortcuts stay out of the accessible names", async () => {
  const card = await render();
  const buttons = [...card.querySelectorAll<HTMLButtonElement>("button[data-decision]")];
  expect(buttons.map((button) => button.getAttribute("aria-label"))).toEqual([
    "Deny",
    "Allow for this chat",
    "Allow once",
  ]);
  expect(buttons.filter((button) => button.dataset.variant === "primary").map((b) => b.dataset.decision)).toEqual([
    "allow_once",
  ]);
  for (const kbd of card.querySelectorAll("kbd")) expect(kbd.getAttribute("aria-hidden")).toBe("true");
});

test("one disclosure: no separate Expand button; the request row expands", async () => {
  const card = await render();
  expect([...card.querySelectorAll("button")].some((button) => button.textContent?.includes("Expand"))).toBe(false);
  const details = card.querySelector("details")!;
  expect(details.open).toBe(false);
  await act(async () => card.querySelector<HTMLElement>("summary")!.click());
  expect(details.open).toBe(true);
});

test("the chat scope note is the secondary button's description, and isolation is a chip inside the card", async () => {
  const card = await render();
  const chat = card.querySelector<HTMLButtonElement>('button[data-decision="allow_chat"]')!;
  expect(chat.getAttribute("title")).toContain("future eligible requests");
  expect(card.textContent).not.toContain("future eligible requests");
  const chip = card.querySelector<HTMLElement>("[data-permission-isolation]")!;
  expect(chip.textContent).toContain("Isolation unverified");
  expect(chip.getAttribute("title")).toContain("Host isolation is unverified");
});

test("holding Option-Command shows the shortcut hints", async () => {
  const card = await render();
  expect(card.dataset.hints).toBe("false");
  await act(async () =>
    dom.window.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Meta", metaKey: true, altKey: true })),
  );
  expect(card.dataset.hints).toBe("true");
  await act(async () => dom.window.dispatchEvent(new dom.window.KeyboardEvent("keyup", { key: "Alt", metaKey: true })));
  expect(card.dataset.hints).toBe("false");
});

test("several requests: the title counts them and each request is its own expandable row", async () => {
  const second = {
    permissionId: "q",
    state: "pending" as const,
    request: { toolCall: { title: "Write app.ts", kind: "edit", rawInput: { path: "app.ts" } } },
  };
  const card = await render(state([{ ...one, items: [...one.items, second] }]));
  expect(card.querySelector("[data-permission-title]")!.textContent).toBe("2 requests from this turn");
  const rows = [...card.querySelectorAll("details summary")].map((summary) => summary.textContent);
  expect(rows[0]).toContain("cmux harness guide");
  expect(rows[1]).toContain("Write app.ts");
});
