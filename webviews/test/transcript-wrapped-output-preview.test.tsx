// l10n-allow-file: test fixture output and commands, not shipped UI.
// Long tool outputs collapse with Show more (Leo 2026-10-22: "also the tool calling i think there
// should be more of like a "show more" type thing for long outputs or whatnot..."). A block of more
// than eight lines already showed its first eight under a fade with "Show all N lines"
// (transcript-block-overflow.test.tsx); a few lines that wrap to many rows (a one-line JSON result,
// a minified log line) ran on unbounded. Now they are cut at eight rows too, with "Show more", and
// "Show less" closes them again. The rows are read from the block's own height only: jsdom has no
// layout, so its height here is its text's rows at `columns` characters a row, and its
// ResizeObserver fires when the test narrows or widens it.
import { afterAll, afterEach, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "Element",
  "Node",
  "customElements",
  "MutationObserver",
  "ResizeObserver",
  "localStorage",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
const added: string[] = [];
let root: Root | undefined;
let host: HTMLElement;
let window: JSDOM["window"];
// The first diff card imports Pierre's chunk, which takes seconds cold.
setDefaultTimeout(30_000);

beforeAll(() => {
  ({ window } = new JSDOM("<!doctype html><div id=root></div>", { url: "http://localhost/", pretendToBeVisual: true }));
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    Element: window.Element,
    Node: window.Node,
    customElements: window.customElements,
    MutationObserver: window.MutationObserver,
    // jsdom has no layout; Pierre's lines and the blocks' edges watch their size.
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    localStorage: window.localStorage,
    requestAnimationFrame: window.requestAnimationFrame.bind(window),
    cancelAnimationFrame: window.cancelAnimationFrame.bind(window),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  for (const key of Object.getOwnPropertyNames(window))
    if (/^(HTML|SVG|CSS|Shadow|Document|Event|MouseEvent)/.test(key) && !(key in scope)) {
      added.push(key);
      scope[key] = (window as unknown as Record<string, unknown>)[key];
    }
  host = window.document.getElementById("root")!;
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  window.localStorage.clear();
});

afterAll(() => {
  for (const key of added) delete scope[key];
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

async function render(node: React.ReactNode) {
  const { createRoot } = await import("react-dom/client");
  root = createRoot(host);
  await act(async () => root!.render(node));
}

const click = (element: Element | null | undefined) =>
  act(async () => {
    // A boolean, so a miss prints one line rather than the element's whole React tree.
    expect(Boolean(element)).toBe(true);
    element!.dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  });

const buttons = (within: ParentNode = host) => [...within.querySelectorAll("button")];
const named = (label: string, within: ParentNode = host) =>
  buttons(within).filter((node) => (node.getAttribute("aria-label") ?? node.textContent) === label);
const byText = (text: string, within: ParentNode = host) => buttons(within).find((node) => node.textContent === text);

/// The characters one row of a block holds; a test changes it and fires `resize` to narrow or widen.
let columns = 80;
const observers = new Set<() => void>();
const resize = (to: number) =>
  act(async () => {
    columns = to;
    for (const fire of observers) fire();
  });

beforeAll(() => {
  scope.ResizeObserver = window.ResizeObserver = class {
    #fire: () => void;
    constructor(fire: (entries: unknown[], observer: unknown) => void) {
      this.#fire = () => fire([], this);
    }
    observe() {
      observers.add(this.#fire);
    }
    unobserve() {}
    disconnect() {
      observers.delete(this.#fire);
    }
  } as never;
  const style = window.getComputedStyle.bind(window);
  window.getComputedStyle = ((node: Element) =>
    node.matches("pre")
      ? { lineHeight: "18px", paddingTop: "8px", paddingBottom: "8px", rowGap: "normal" }
      : style(node)) as never;
  // A block's whole height: each of its lines' rows at `columns` characters, and its padding.
  Object.defineProperty(window.HTMLElement.prototype, "scrollHeight", {
    configurable: true,
    get(this: HTMLElement) {
      if (!this.matches("pre")) return 0;
      const rows = [...this.querySelectorAll(".cv-line")]
        .map((line) => line.textContent!.replace(/\n$/, ""))
        .reduce((sum, line) => sum + Math.max(1, Math.ceil(line.length / columns)), 0);
      return rows * 18 + 16;
    },
  });
});

afterEach(() => {
  columns = 80;
});

const call = (kind: string, output: string, command?: string) =>
  ({
    kind: "activity",
    text: "Ran",
    tool: { id: `${kind}-call`, kind, title: "Tool", status: "completed", command, output },
  }) as never;

async function openRow(kind: string, output: string, command?: string) {
  const { ToolRow } = await import("../src/agent-session/acpmux/conversation/ToolRow");
  await render(<ToolRow item={call(kind, output, command)} />);
  await click(host.querySelector("button.cv-tool"));
}

/// A one-line JSON result of about 1,400 characters: 18 rows at 80 a row.
const ONE_LINE = JSON.stringify({
  items: Array.from({ length: 60 }, (_, index) => `item-${index + 1}-of-the-feed`),
  ok: true,
});

test("a call's one-line output that wraps past eight rows is cut under a fade with Show more", async () => {
  expect(ONE_LINE.includes("\n")).toBe(false);
  expect(ONE_LINE.length).toBeGreaterThan(9 * 80);
  await openRow("fetch", ONE_LINE);
  const card = host.querySelector(".cv-tool-output-card")!;
  const body = card.querySelector(".cv-tool-output")!;
  expect(body.getAttribute("data-preview")).toBe("cut");
  const more = byText("Show more", card);
  expect(more?.getAttribute("aria-expanded")).toBe("false");
  // A real button, so Tab reaches it and Return or Space opens it; Find skips its words.
  expect(more?.tagName).toBe("BUTTON");
  expect(more?.hasAttribute("data-find-skip")).toBe(true);
  // Never "Show all 1 lines": the count is only for blocks cut by their lines.
  expect(buttons(card).some((node) => node.textContent?.startsWith("Show all"))).toBe(false);
  // The whole text is drawn, only clipped: Copy and Find read all of it.
  expect(body.textContent).toBe(ONE_LINE);
  await click(more);
  expect(body.getAttribute("data-preview")).toBe("all");
  const less = byText("Show less", card);
  expect(less?.getAttribute("aria-expanded")).toBe("true");
  await click(less);
  expect(body.getAttribute("data-preview")).toBe("cut");
  expect(Boolean(byText("Show more", card))).toBe(true);
});

test("an output that wraps to eight rows or fewer shows whole, with no toggle", async () => {
  // 600 characters: 8 rows at 80 a row.
  await openRow("fetch", "x".repeat(600));
  const card = host.querySelector(".cv-tool-output-card")!;
  expect(card.querySelector(".cv-tool-output")?.hasAttribute("data-preview")).toBe(false);
  expect(buttons(card).some((node) => /^Show (more|less|all)/.test(node.textContent ?? ""))).toBe(false);
  // Short lines never wrap, so a short output is not even measured.
  act(() => root?.unmount());
  await openRow("fetch", "3 pass\n0 fail");
  expect(host.querySelector(".cv-tool-output")?.hasAttribute("data-preview")).toBe(false);
});

test("narrowing the chat cuts an output that now wraps past eight rows, and widening it again shows it whole", async () => {
  await openRow("fetch", "x".repeat(600));
  const body = () => host.querySelector(".cv-tool-output")!;
  expect(body().hasAttribute("data-preview")).toBe(false);
  await resize(40);
  expect(body().getAttribute("data-preview")).toBe("cut");
  expect(Boolean(byText("Show more"))).toBe(true);
  await resize(120);
  expect(body().hasAttribute("data-preview")).toBe(false);
  expect(Boolean(byText("Show more"))).toBe(false);
});

test("with Wrap lines off a long line stays on one row and is not cut", async () => {
  await openRow("fetch", ONE_LINE);
  const card = host.querySelector(".cv-tool-output-card")!;
  await click(named("Wrap lines", card)[0]);
  expect(card.querySelector(".cv-tool-output")?.getAttribute("data-wrap")).toBe("false");
  expect(card.querySelector(".cv-tool-output")?.hasAttribute("data-preview")).toBe(false);
  expect(Boolean(byText("Show more", card))).toBe(false);
});

test("a Shell block whose few lines wrap past eight rows is cut with Show more too", async () => {
  await openRow("execute", ONE_LINE, "curl -s https://example.test/items");
  const shell = host.querySelector(".cv-shell")!;
  expect(shell.querySelector(".cv-shell__body")?.getAttribute("data-preview")).toBe("cut");
  await click(byText("Show more", shell));
  expect(shell.querySelector(".cv-shell__body")?.getAttribute("data-preview")).toBe("all");
  expect(Boolean(byText("Show less", shell))).toBe(true);
});

test("Find in Chat revealing the call opens an output cut for its wrapped rows", async () => {
  const { ShellBlock } = await import("../src/agent-session/acpmux/conversation/ShellBlock");
  await render(<ShellBlock command="curl -s https://example.test/items" output={ONE_LINE} reveal={0} />);
  expect(host.querySelector(".cv-shell__body")?.getAttribute("data-preview")).toBe("cut");
  // As ToolRow passes it: bumped each time Find reveals the row.
  await act(async () =>
    root!.render(<ShellBlock command="curl -s https://example.test/items" output={ONE_LINE} reveal={1} />),
  );
  expect(host.querySelector(".cv-shell__body")?.getAttribute("data-preview")).toBe("all");
  expect(Boolean(byText("Show less"))).toBe(true);
});

test("a block opened whole for a permission ask is never cut", async () => {
  const { ShellBlock } = await import("../src/agent-session/acpmux/conversation/ShellBlock");
  await render(<ShellBlock command="curl -s https://example.test/items" output={ONE_LINE} whole />);
  expect(host.querySelector(".cv-shell__body")?.hasAttribute("data-preview")).toBe(false);
});

test("the tool-output-collapse experiment's arm sets the rows a block shows before it cuts", async () => {
  const twelve = Array.from({ length: 12 }, (_, index) => `line ${index + 1}`).join("\n");
  try {
    // Fifteen rows: twelve lines show whole.
    globalThis.cmuxExperiments = { "tool-output-collapse": "fifteen-link" };
    await openRow("fetch", twelve);
    const card = host.querySelector(".cv-tool-output-card")!;
    expect(card.getAttribute("data-collapse")).toBe("fifteen-link");
    expect((card as HTMLElement).style.getPropertyValue("--cv-preview-rows")).toBe("15");
    expect(card.querySelector(".cv-tool-output")?.hasAttribute("data-preview")).toBe(false);
    act(() => root?.unmount());
    // Six rows: the same twelve lines are cut.
    globalThis.cmuxExperiments = { "tool-output-collapse": "six-bar" };
    await openRow("fetch", twelve);
    expect(host.querySelector(".cv-tool-output")?.getAttribute("data-preview")).toBe("cut");
    expect(Boolean(byText("Show all 12 lines"))).toBe(true);
  } finally {
    globalThis.cmuxExperiments = undefined;
  }
});

test("the shipped arm cuts at eight rows, as before", async () => {
  await openRow("fetch", Array.from({ length: 9 }, (_, index) => `line ${index + 1}`).join("\n"));
  const card = host.querySelector(".cv-tool-output-card")!;
  expect(card.getAttribute("data-collapse")).toBe("fade-link");
  expect(card.querySelector(".cv-tool-output")?.getAttribute("data-preview")).toBe("cut");
  expect(Boolean(byText("Show all 9 lines", card))).toBe(true);
});
