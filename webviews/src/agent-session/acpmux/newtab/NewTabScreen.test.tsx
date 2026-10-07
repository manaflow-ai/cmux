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
  expect(field.placeholder).toBe("Search or type a URL");
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

// The page's folder is added by screenActions (screenActions.test.ts).
test("Enter in shell mode hands the command to a chat; no terminal opens", async () => {
  const { root, type, key, calls } = await mount();
  await type("!npm test");
  await key("Enter");
  expect(calls).toEqual(["shell:npm test"]);
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

// No flash (Lawrence, 2026-10-06): the first commit is already the final layout. The pill field
// has the keyboard, "Chats" with "All Chats" heads exactly three cards from the sessions already
// in memory, and nothing else is on the page (no rows, no project row, no chat-first controls).
test("the first commit is the final layout: field, Chats and three cards", async () => {
  const sessions = [1, 2, 3, 4].map((n) => ({ sessionId: `c${n}`, title: `chat ${n}`, updatedAt: now - n * 60_000 }));
  const { container, root, field } = await mount({ snapshot: { ...snapshot, sessions } });
  const screen = container.querySelector(".nt-screen")!;
  expect([...screen.children].map((child) => child.className)).toEqual(["nt-box", "nt-chats"]);
  expect(dom.window.document.activeElement).toBe(field);
  expect(field.placeholder).toBe("Search or type a URL");
  expect(container.querySelector(".nt-chats-tab")!.textContent).toBe("Chats");
  expect(container.querySelector(".nt-chats-all")!.textContent).toBe("All Chats");
  expect([...container.querySelectorAll(".nt-card-title")].map((title) => title.textContent)).toEqual([
    "chat 1",
    "chat 2",
    "chat 3",
  ]);
  expect(container.querySelectorAll(".nt-box button").length).toBe(0);
  await act(async () => root.unmount());
});

// The original one-input page (Lawrence, 2026-10-06, NEW-TAB-PAGE-RESTORED): Enter on an empty
// field opens nothing, and the page has no project row or Import button above its field.
test("Enter on an untouched new tab opens nothing", async () => {
  const { root, key, calls } = await mount({ cwd: "/src/app", lastAgent: "codex" });
  await key("Enter");
  expect(calls).toEqual([]);
  await act(async () => root.unmount());
});

test("the page is one field: no project chooser or Import button above it", async () => {
  const { container, root } = await mount({
    cwd: "/src/old",
    projects: [{ cwd: "/src/new", label: "new" }],
    onImport: () => {},
    onBrowseProject: async () => "/src/picked",
  });
  expect(container.querySelector(".nt-project")).toBeNull();
  expect(container.querySelector(".acpmux-project-button")).toBeNull();
  expect([...container.querySelectorAll("button")].map((button) => button.textContent)).not.toContain(
    "Import and sync",
  );
  await act(async () => root.unmount());
});

test("typed text offers no app action rows", async () => {
  const { container, root, type } = await mount({
    omnibar: {
      tabs: [],
      workspaces: [],
      sessions: [],
      folders: [],
      commands: [],
      history: [],
      actions: [{ id: "keybindings.open", title: "Keyboard Shortcuts", keywords: ["preferences"] }],
    },
  });
  await type("Keyboard");
  const titles = [...container.querySelectorAll(".nt-row-title")].map((row) => row.textContent);
  expect(titles).not.toContain("Keyboard Shortcuts");
  await act(async () => root.unmount());
});
