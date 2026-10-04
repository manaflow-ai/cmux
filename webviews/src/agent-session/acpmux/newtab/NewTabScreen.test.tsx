import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxSnapshot } from "../model";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
const saved = Object.fromEntries(
  ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT"].map((key) => [key, globals[key]]),
);
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  IS_REACT_ACT_ENVIRONMENT: true,
});
afterAll(() => Object.assign(globals, saved));

const { act, createElement } = await import("react");
const { createRoot } = await import("react-dom/client");
const { NewTabScreen } = await import("./NewTabScreen");

/// Sends the edit straight to React's onChange (see NewTabPage.test.tsx: another file's
/// react-dom copy can ignore jsdom "input" events).
function edited(field: HTMLInputElement) {
  const key = Object.keys(field).find((name) => name.startsWith("__reactProps$"));
  const props = key ? (field as unknown as Record<string, { onChange?: (event: unknown) => void }>)[key] : undefined;
  props?.onChange?.({ target: field, currentTarget: field });
}

const now = 1_000_000_000;
const snapshot = {
  type: "snapshot",
  protocolVersion: 1,
  rows: [],
  sessions: [
    { sessionId: "s1", title: "Fix upload", updatedAt: now - 120_000, preview: "Done, tests pass." },
    { sessionId: "s2", title: "Billing", updatedAt: now - 3_600_000, status: "disconnected" },
  ],
  connection: "connected",
  isWorking: false,
  queue: [],
  catalog: [
    { id: "claude", name: "Claude Code", models: [] },
    { id: "codex", name: "Codex", models: [] },
  ],
  canLoadOlder: false,
} as unknown as AcpmuxSnapshot;

async function mount(extra: Record<string, unknown> = {}) {
  const calls: string[] = [];
  const container = dom.window.document.getElementById("root")!;
  const root = createRoot(container);
  const record =
    (name: string) =>
    (...args: unknown[]) =>
      calls.push([name, ...args].join(":"));
  await act(async () =>
    root.render(
      createElement(NewTabScreen, {
        snapshot,
        now,
        onAsk: record("ask"),
        onOpen: record("open"),
        onSearch: record("search"),
        onTerminal: record("terminal"),
        onTypeAhead: record("typeAhead"),
        onJump: record("jump"),
        onOpenSession: record("session"),
        onShowAll: record("all"),
        ...extra,
      }),
    ),
  );
  const field = container.querySelector<HTMLInputElement>(".nt-field")!;
  const setValue = Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, "value")!.set!;
  const type = (value: string) =>
    act(async () => {
      setValue.call(field, value);
      edited(field);
    });
  const key = (name: string, init: KeyboardEventInit = {}) =>
    act(async () => {
      field.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: name, bubbles: true, ...init }));
    });
  return { container, root, field, type, key, calls };
}

test("the field has the keyboard when the screen appears, and the cards show recent chats", async () => {
  const { container, root, field } = await mount();
  expect(dom.window.document.activeElement).toBe(field);
  expect(field.placeholder).toBe("Search or type a URL");
  const cards = [...container.querySelectorAll(".nt-card")];
  expect(cards.map((card) => card.querySelector(".nt-card-title")!.textContent)).toEqual(["Fix upload", "Billing"]);
  expect(cards[0]!.querySelector(".nt-card-message")!.textContent).toBe("Done, tests pass.");
  expect(cards[1]!.getAttribute("data-state")).toBe("error");
  expect(container.querySelector(".nt-rows")).toBeNull();
  await act(async () => root.unmount());
});

test("! turns the tab into a terminal at once and forwards what follows", async () => {
  const { container, root, type, calls } = await mount();
  await type("!");
  expect(calls).toEqual(["terminal:"]);
  expect(container.querySelector(".nt-chats")).toBeNull();
  await type("!gi");
  await type("!git status");
  expect(calls).toEqual(["terminal:", "typeAhead:gi", "typeAhead:git status"]);
  await act(async () => root.unmount());
});

// R81: the "!" frame shows the terminal at once (a placeholder over the same background, the
// typed command and a cursor) while the daemon starts the shell; the field keeps the keyboard.
test("! shows a terminal placeholder in the same render, echoing what is typed", async () => {
  const { container, root, field, type } = await mount();
  await type("!");
  const terminal = container.querySelector(".nt-terminal");
  expect(terminal).not.toBeNull();
  expect(container.querySelector(".nt-screen")!.hasAttribute("data-converting")).toBe(true);
  expect(container.querySelector(".nt-terminal .nt-cursor")).not.toBeNull();
  await type("!ls -la");
  expect(container.querySelector(".nt-terminal-command")!.textContent).toBe("ls -la");
  expect(dom.window.document.activeElement).toBe(field);
  await act(async () => root.unmount());
});

test("one input (R86): a prompt lists the agents and an explicit search row; no Search/Ask mode", async () => {
  const { container, root, type, key, calls } = await mount();
  await type("fix the build");
  const titles = () => [...container.querySelectorAll(".nt-row")].map((row) => row.getAttribute("data-type"));
  expect(titles()).toEqual(["agent", "agent", "search"]);
  // Each agent row wears its brand mark (design/agent-icons).
  const marks = [...container.querySelectorAll('.nt-row[data-type="agent"] svg.agent-mark')];
  expect(marks.map((svg) => svg.getAttribute("data-agent"))).toEqual(["claude", "openai"]);
  expect(container.querySelector(".nt-mode")).toBeNull();
  await key("Enter");
  expect(calls).toEqual(["ask:claude:fix the build"]);
  await key("ArrowDown");
  await key("ArrowDown");
  await key("Enter");
  expect(calls).toEqual(["ask:claude:fix the build", "search:fix the build"]);
  await act(async () => root.unmount());
});

test("an address opens on Enter; Down then Enter picks the next row", async () => {
  const { root, type, key, calls } = await mount();
  await type("localhost:3000");
  await key("Enter");
  expect(calls).toEqual(["open:http://localhost:3000"]);
  await key("ArrowDown");
  await key("Enter");
  expect(calls).toEqual(["open:http://localhost:3000", "search:localhost:3000"]);
  await act(async () => root.unmount());
});

test("the remembered agent comes from the host and leads the rows", async () => {
  const { root, type, key, calls } = await mount({ lastAgent: "codex" });
  await type("hello");
  await key("Enter");
  expect(calls).toEqual(["ask:codex:hello"]);
  await act(async () => root.unmount());
});

test("a card opens its chat and All Chats opens the list", async () => {
  const { container, root, calls } = await mount();
  await act(async () => {
    container.querySelector<HTMLButtonElement>(".nt-card")!.click();
    container.querySelector<HTMLButtonElement>(".nt-chats-all")!.click();
  });
  expect(calls).toEqual(["session:s1", "all"]);
  await act(async () => root.unmount());
});
