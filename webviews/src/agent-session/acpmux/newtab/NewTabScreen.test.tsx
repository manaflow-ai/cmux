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
  const touches: string[] = [];
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
        onShell: record("shell"),
        onJump: record("jump"),
        onOpenSession: record("session"),
        onShowAll: record("all"),
        onTouched: () => touches.push("touched"),
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
  return { container, root, field, type, key, calls, touches };
}

test("the field has the keyboard when the screen appears, and the cards show recent chats", async () => {
  const { container, root, field } = await mount();
  expect(dom.window.document.activeElement).toBe(field);
  expect(field.placeholder).toBe("Ask an agent, search, or type a URL");
  const cards = [...container.querySelectorAll(".nt-card")];
  expect(cards.map((card) => card.querySelector(".nt-card-title")!.textContent)).toEqual(["Fix upload", "Billing"]);
  expect(cards[0]!.querySelector(".nt-card-message")!.textContent).toBe("Done, tests pass.");
  expect(cards[1]!.getAttribute("data-state")).toBe("error");
  expect(container.querySelector(".nt-rows")).toBeNull();
  await act(async () => root.unmount());
});

test("! puts the field in shell mode in place: no terminal, no rows, the cards stay", async () => {
  const { container, root, field, type, calls } = await mount();
  await type("!");
  expect(calls).toEqual([]);
  const screen = container.querySelector(".nt-screen")!;
  expect(screen.hasAttribute("data-shell")).toBe(true);
  expect(field.value).toBe("");
  expect(container.querySelector(".nt-shell-glyph")?.textContent).toBe("!");
  await type("git status");
  expect(container.querySelector(".nt-rows")).toBeNull();
  // Stability: the recent chats do not unmount for a mode.
  expect(container.querySelectorAll(".nt-card").length).toBeGreaterThan(0);
  expect(dom.window.document.activeElement).toBe(field);
  await act(async () => root.unmount());
});

test("Enter in shell mode starts a chat in the chosen folder that runs the command", async () => {
  const { root, type, key, calls } = await mount({ cwd: "/src/app" });
  await type("!npm test");
  await key("Enter");
  expect(calls).toEqual(["shell:npm test:/src/app"]);
  await act(async () => root.unmount());
});

test("Backspace on an empty command and Escape leave shell mode, keeping what was typed", async () => {
  const { container, root, field, type, key } = await mount();
  await type("!");
  await key("Backspace");
  expect(container.querySelector(".nt-screen")!.hasAttribute("data-shell")).toBe(false);
  await type("!");
  await type("ls");
  await key("Escape");
  expect(container.querySelector(".nt-screen")!.hasAttribute("data-shell")).toBe(false);
  expect(field.value).toBe("ls");
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

// R81: the host recycles only a strictly untouched page, so the first input reports itself once.
test("the first user input reports the page as touched, once", async () => {
  const { root, type, key, touches } = await mount();
  await key("ArrowDown");
  await type("h");
  await type("he");
  expect(touches).toEqual(["touched"]);
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

test("Enter on an untouched new tab starts the preferred chat in its project", async () => {
  const { root, key, calls } = await mount({ cwd: "/src/app", lastAgent: "codex" });
  await key("Enter");
  expect(calls).toEqual(["ask:codex::/src/app"]);
  await act(async () => root.unmount());
});

test("new tab offers recent projects inline before Browse", async () => {
  const { container, root, key, calls } = await mount({
    cwd: "/src/old",
    projects: [{ cwd: "/src/new", label: "new" }],
  });
  const trigger = container.querySelector<HTMLButtonElement>(".nt-project button")!;
  expect(trigger).not.toBeNull();
  await act(async () => trigger.click());
  const option = container.querySelector<HTMLElement>('[role="option"][title="/src/new"]')!;
  expect(option).not.toBeNull();
  await act(async () => option.dispatchEvent(new dom.window.MouseEvent("mousedown", { bubbles: true })));
  await key("Enter");
  expect(calls).toEqual(["ask:claude::/src/new"]);
  await act(async () => root.unmount());
});
