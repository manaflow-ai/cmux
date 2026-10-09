import { afterAll, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxSnapshot } from "../model";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
const saved = Object.fromEntries(
  [
    "window",
    "document",
    "navigator",
    "HTMLElement",
    "Element",
    "Node",
    "getComputedStyle",
    "requestAnimationFrame",
    "cancelAnimationFrame",
    "IS_REACT_ACT_ENVIRONMENT",
  ].map((key) => [key, globals[key]]),
);
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  // The project picker's popover (base-ui) animates.
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(performance.now()), 0),
  cancelAnimationFrame: (id: number) => clearTimeout(id),
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
      calls.push([name, ...args.filter((arg) => arg !== undefined)].join(":"));
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
  expect(field.placeholder).toBe("Ask anything or type a URL");
  const cards = [...container.querySelectorAll(".nt-card")];
  expect(cards.map((card) => card.querySelector(".nt-card-title")!.textContent)).toEqual(["Fix upload", "Billing"]);
  expect(cards[0]!.querySelector(".nt-card-message")!.textContent).toBe("Done, tests pass.");
  expect(cards[1]!.getAttribute("data-state")).toBe("error");
  expect(container.querySelector(".nt-rows")).toBeNull();
  await act(async () => root.unmount());
});

test("Tools cards use host shortcuts and run their catalog action", async () => {
  const { container, root, calls } = await mount({
    tools: [
      { id: "openDiffViewer", title: "Changes", symbol: "plusminus", shortcut: "⌘G", menu: [] },
      { id: "newSurface", title: "Terminal", symbol: "terminal", shortcut: "⌘T", menu: ["splitRight"] },
    ],
    onRunAction: (id: string) => calls.push(`action:${id}`),
  });
  expect(container.querySelector(".nt-tools h2")?.textContent).toBe("Tools");
  expect([...container.querySelectorAll(".nt-tool-main")].map((button) => button.textContent)).toEqual([
    "±Changes⌘G",
    "›_Terminal⌘T",
  ]);
  await act(async () => {
    container.querySelector<HTMLButtonElement>(".nt-tool-main")!.click();
    container.querySelector<HTMLButtonElement>(".nt-tool-menu-popover button")!.click();
  });
  expect(calls).toEqual(["action:openDiffViewer", "action:splitRight"]);
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

// cx-e2aa (Lawrence 2026-10-09): a prompt shows no rows. Enter asks the agent picked at the top
// of the page, in the project picked there.
test("a prompt shows no rows and Enter asks the picked agent in the page's project", async () => {
  const { container, root, type, key, calls } = await mount({ cwd: "/src/app" });
  await type("fix the build");
  expect(container.querySelector(".nt-rows")).toBeNull();
  expect(container.querySelector('.nt-row[data-type="agent"]')).toBeNull();
  await key("Enter");
  expect(calls).toEqual(["ask:claude:fix the build:/src/app"]);
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

const tabsOmnibar = {
  tabs: [
    { id: "t1", kind: "browser", title: "Release notes", detail: "cmux.dev" },
    { id: "t2", kind: "terminal", title: "release build" },
  ],
  workspaces: [{ id: "w1", name: "Release", detail: "~/src/release" }],
  folders: ["/src/release"],
  commands: ["release"],
  history: [],
};

test("text matching open tabs lists only the tabs and a web search; Enter still asks", async () => {
  const { container, root, type, key, calls } = await mount({ omnibar: tabsOmnibar });
  await type("release");
  const types = [...container.querySelectorAll(".nt-row")].map((row) => row.getAttribute("data-type"));
  expect(types).toEqual(["tab", "tab", "search"]);
  // Nothing is selected until Down or Ctrl-N: Enter is the prompt's.
  expect(container.querySelector(".nt-row.is-selected")).toBeNull();
  await key("Enter");
  expect(calls).toEqual(["ask:claude:release"]);
  await act(async () => root.unmount());
});

// Round-1 design A: rows show where the query matched, with a quiet tint (never an accent), and a
// long page address keeps its host and its end visible, with the full address as the tooltip.
test("rows mark the typed words and compact long page addresses", async () => {
  const url = "https://github.com/manaflow-ai/cmux/pull/18729/files?diff=split&w=1";
  const { container, root, type } = await mount({
    omnibar: { ...tabsOmnibar, history: [{ url, title: "Release PR files" }] },
  });
  await type("release");
  const marks = [...container.querySelectorAll(".nt-row-title mark")].map((mark) => mark.textContent);
  expect(marks.length).toBeGreaterThan(0);
  expect(marks.every((text) => text?.toLowerCase() === "release")).toBe(true);
  const detail = [...container.querySelectorAll<HTMLElement>(".nt-row-detail")].find((node) => node.title === url);
  expect(detail).toBeDefined();
  expect(detail!.textContent).toContain("github.com/");
  expect(detail!.textContent).toContain("…");
  await act(async () => root.unmount());
});

test("Ctrl-N and Ctrl-P move through the rows as Down and Up do", async () => {
  const { container, root, type, key, calls } = await mount({ omnibar: tabsOmnibar });
  await type("release");
  const selected = () => container.querySelector(".nt-row.is-selected")?.getAttribute("data-type");
  await key("n", { ctrlKey: true });
  expect(selected()).toBe("tab");
  await key("n", { ctrlKey: true });
  await key("n", { ctrlKey: true });
  expect(selected()).toBe("search");
  await key("p", { ctrlKey: true });
  await key("Enter");
  expect(calls).toEqual(["jump:tab:t2"]);
  await act(async () => root.unmount());
});

test("Enter asks the remembered agent from the host", async () => {
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

// No flash (Lawrence, 2026-10-06): the first commit is already the final layout. The pickers sit on
// top (cx-e2aa, 2026-10-09), the pill field has the keyboard, "Chats" with "All Chats" heads exactly
// three cards from the sessions already in memory, and there are no rows.
test("the first commit is the final layout: pickers, field, Chats and three cards", async () => {
  const sessions = [1, 2, 3, 4].map((n) => ({ sessionId: `c${n}`, title: `chat ${n}`, updatedAt: now - n * 60_000 }));
  const { container, root, field } = await mount({ snapshot: { ...snapshot, sessions } });
  const screen = container.querySelector(".nt-screen")!;
  expect([...screen.children].map((child) => child.className)).toEqual(["nt-pickers", "nt-box", "nt-chats"]);
  expect(dom.window.document.activeElement).toBe(field);
  expect(field.placeholder).toBe("Ask anything or type a URL");
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
// field opens nothing.
test("Enter on an untouched new tab opens nothing", async () => {
  const { root, key, calls } = await mount({ cwd: "/src/app", lastAgent: "codex" });
  await key("Enter");
  expect(calls).toEqual([]);
  await act(async () => root.unmount());
});

// cx-e2aa (Lawrence 2026-10-09): "project picker + model/effort/speed picker should be on top".
test("the project picker and the agent's model chip sit above the field", async () => {
  const chips: string[] = [];
  const Chips = ({ snapshot, cwd }: { snapshot: AcpmuxSnapshot; cwd?: string }) => {
    chips.push(`${snapshot.summary?.harness}:${cwd}`);
    return createElement("span", { className: "test-chips" }, "model");
  };
  const { container, root, key, type, calls } = await mount({
    cwd: "/src/old",
    lastAgent: "codex",
    projects: [
      { cwd: "/src/old", label: "old" },
      { cwd: "/src/new", label: "new" },
    ],
    chips: Chips,
  });
  const pickers = container.querySelector(".nt-pickers")!;
  expect(pickers.nextElementSibling?.className).toBe("nt-box");
  expect(pickers.querySelector(".acpmux-project-button")?.textContent).toContain("old");
  expect(pickers.querySelector(".test-chips")).not.toBeNull();
  // The chip shows the agent Enter asks, in the page's project.
  expect(chips.at(-1)).toBe("codex:/src/old");
  await act(async () => pickers.querySelector<HTMLButtonElement>(".acpmux-project-button")!.click());
  const option = [...dom.window.document.querySelectorAll<HTMLElement>('[role="option"]')].find(
    (row) => row.querySelector(".acpmux-menu-label")?.textContent === "new",
  )!;
  await act(async () => {
    option.dispatchEvent(new dom.window.MouseEvent("mousedown", { bubbles: true, cancelable: true }));
  });
  expect(chips.at(-1)).toBe("codex:/src/new");
  await type("ship it");
  await key("Enter");
  expect(calls).toEqual(["ask:codex:ship it:/src/new"]);
  await act(async () => root.unmount());
});

// cx-e2aa (Lawrence 2026-10-09): "if i just start typing it needs to automatically start typing".
test("a key typed anywhere on the page goes into the field, the first key kept", async () => {
  const { container, root, field, touches } = await mount();
  const card = container.querySelector<HTMLButtonElement>(".nt-card")!;
  card.focus();
  expect(dom.window.document.activeElement).toBe(card);
  const press = (target: Element, key: string, init: KeyboardEventInit = {}) =>
    act(async () => {
      target.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key, bubbles: true, cancelable: true, ...init }));
    });
  await press(card, "h");
  expect(dom.window.document.activeElement).toBe(field);
  expect(field.value).toBe("h");
  expect(touches).toEqual(["touched"]);
  await press(dom.window.document.body, "i");
  expect(field.value).toBe("hi");
  // Chords stay the app's.
  card.focus();
  await press(card, "k", { metaKey: true });
  expect(field.value).toBe("hi");
  await act(async () => root.unmount());
});

test("Space on a focused button presses it; a typed key replaces a still-selected location", async () => {
  const { container, root, field } = await mount({ location: "https://cmux.dev/" });
  const card = container.querySelector<HTMLButtonElement>(".nt-card")!;
  card.focus();
  await act(async () => {
    card.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: " ", bubbles: true, cancelable: true }));
  });
  expect(dom.window.document.activeElement).toBe(card);
  expect(field.value).toBe("https://cmux.dev/");
  field.select();
  card.focus();
  await act(async () => {
    card.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "g", bubbles: true, cancelable: true }));
  });
  expect(field.value).toBe("g");
  await act(async () => root.unmount());
});

test("a key typed in another field on the page stays in that field", async () => {
  const { root, field } = await mount();
  const other = dom.window.document.createElement("input");
  dom.window.document.querySelector(".nt-screen")!.append(other);
  other.focus();
  await act(async () => {
    other.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "x", bubbles: true, cancelable: true }));
  });
  expect(dom.window.document.activeElement).toBe(other);
  expect(field.value).toBe("");
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

test("New Tab acknowledges the input generation only after the field has focus", async () => {
  const seen: string[] = [];
  const { root } = await mount({
    inputToken: "opening-1",
    onInputReady: (token: string) => {
      expect(dom.window.document.activeElement?.className).toBe("nt-field");
      seen.push(token);
    },
  });
  expect(seen).toEqual(["opening-1"]);
  await act(async () => root.unmount());
});

// Dogfood 2026-10-08 (01): with chat cards under it the rows box shrank to two rows, and Down
// to a row below them selected it out of sight ("I select lowest, it doesn't jump").
test("Down to a row out of sight scrolls the rows box to it, and only the box", async () => {
  // jsdom has no layout: the box shows 100 px and each row is 40 px tall.
  const proto = dom.window.HTMLElement.prototype;
  const original = proto.getBoundingClientRect;
  proto.getBoundingClientRect = function (this: HTMLElement) {
    const index = /^nt-row-(\d+)$/.exec(this.id)?.[1];
    const top = this.id === "nt-rows" ? 0 : index === undefined ? 0 : Number(index) * 40;
    const height = this.id === "nt-rows" ? 100 : index === undefined ? 0 : 40;
    return { top, bottom: top + height, left: 0, right: 100, width: 100, height, x: 0, y: top } as DOMRect;
  };
  try {
    const { root, type, key } = await mount({ omnibar: tabsOmnibar });
    await type("release");
    const box = dom.window.document.getElementById("nt-rows")!;
    let scrollTop = 0;
    Object.defineProperty(box, "scrollTop", { get: () => scrollTop, set: (value: number) => (scrollTop = value) });
    const screen = box.closest<HTMLElement>(".nt-screen");
    await key("ArrowDown");
    await key("ArrowDown");
    expect(scrollTop).toBe(0);
    await key("ArrowDown");
    expect(scrollTop).toBe(20);
    expect(screen?.scrollTop ?? 0).toBe(0);
    await act(async () => root.unmount());
  } finally {
    proto.getBoundingClientRect = original;
  }
});

test("the rows box keeps its height when chat cards and tools fill the screen", () => {
  const css = readFileSync(new URL("./screen.css", import.meta.url), "utf8");
  const rows = css.match(/\.nt-rows\{([^}]*)\}/)?.[1] ?? "";
  expect(rows.split(";")).toContain("flex:none");
});

test("each screen template keeps the field and changes only what shows around it", async () => {
  const tools = [{ id: "openDiffViewer", title: "Changes", symbol: "plusminus", menu: [] }];
  const shown = async (template?: string) => {
    const { container, root, field } = await mount({ template, tools, onAddHarness: () => undefined });
    const result = {
      focused: dom.window.document.activeElement === field,
      cards: container.querySelectorAll(".nt-card").length,
      variant: container.querySelector(".nt-cards")?.getAttribute("data-variant") ?? null,
      tools: container.querySelector(".nt-tools") !== null,
      harness: container.querySelector(".nt-add-harness") !== null,
      prompt: container.querySelector(".nt-prompt-glyph")?.textContent ?? null,
      template: container.querySelector(".nt-screen")!.getAttribute("data-template"),
    };
    await act(async () => root.unmount());
    return result;
  };
  expect(await shown()).toEqual({
    focused: true,
    cards: 2,
    variant: "cards",
    tools: true,
    harness: true,
    prompt: null,
    template: "default",
  });
  expect(await shown("composer")).toEqual({
    focused: true,
    cards: 0,
    variant: null,
    tools: false,
    harness: false,
    prompt: null,
    template: "composer",
  });
  expect(await shown("threads")).toEqual({
    focused: true,
    cards: 2,
    variant: "list",
    tools: false,
    harness: false,
    prompt: null,
    template: "threads",
  });
  expect(await shown("console")).toEqual({
    focused: true,
    cards: 2,
    variant: "list",
    tools: false,
    harness: false,
    prompt: ">",
    template: "console",
  });
});

test("the Console prompt glyph gives way to shell mode's !", async () => {
  const { container, root, type } = await mount({ template: "console" });
  await type("!");
  expect(container.querySelector(".nt-prompt-glyph")).toBeNull();
  expect(container.querySelector(".nt-shell-glyph")?.textContent).toBe("!");
  await act(async () => root.unmount());
});
