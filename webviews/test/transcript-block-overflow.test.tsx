// l10n-allow-file: test fixture paths, commands and file text, not shipped UI.
// Tool-call blocks in the agent chat (Leo 2026-10-21, "Edited codex-excursions.md +21 -0"): a long
// line ran off the block's right edge with no scrollbar and no sign there was more, a long block
// was a 240px box with a hard bottom edge, and there was no way to wrap.
//
// Now: a prose file (md, txt) wraps with a hanging indent by default and code stays on one line,
// with a fade at the right edge while more of it lies past it. Each block's header has Wrap lines
// beside Copy, remembered per kind of block (prose, code, output). A block longer than eight lines
// shows its first eight under a fade, with "Show all N lines". The same holds for a command's Shell
// block and a call's output.
import { afterAll, afterEach, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
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

const lines = (count: number, make = (index: number) => `line ${index + 1}`) =>
  Array.from({ length: count }, (_, index) => make(index)).join("\n") + "\n";

/// A file the agent wrote whole (a new file), as the transcript diffs it.
async function newFile(filePath: string, text: string) {
  const { toolFiles } = await import("../src/agent-session/acpmux/diff");
  return toolFiles([
    {
      id: `edit-${filePath}`,
      title: `Write ${filePath}`,
      kind: "edit",
      status: "completed",
      diffs: [{ path: filePath, oldText: null, newText: text }],
    } as never,
  ])[0]!;
}

async function renderDiffs(...files: Awaited<ReturnType<typeof newFile>>[]) {
  const { EditDiff } = await import("../src/agent-session/acpmux/conversation/EditDiff");
  await render(
    <>
      {files.map((file) => (
        <EditDiff key={file.path} file={file} />
      ))}
    </>,
  );
}

const card = (name: string) =>
  [...host.querySelectorAll(".cv-edit-diff")].find(
    (node) => node.querySelector(".cv-edit-diff__name")?.textContent === name,
  )!;
const wrapOf = (block: Element) => named("Wrap lines", block)[0];

test("a prose file wraps by default and code does not; Wrap lines sits beside Copy in the header", async () => {
  const long = `${"word ".repeat(60)}\n`;
  await renderDiffs(await newFile("/w/docs/codex-excursions.md", long), await newFile("/w/src/app.ts", long));
  for (const [name, wraps] of [
    ["codex-excursions.md", "true"],
    ["app.ts", "false"],
  ] as const) {
    const block = card(name);
    const wrap = wrapOf(block);
    expect(wrap?.getAttribute("aria-pressed")).toBe(wraps);
    expect(block.getAttribute("data-wrap")).toBe(wraps);
    // In the header, right before Copy diff.
    const header = block.querySelector(".cv-edit-diff__header")!;
    expect(wrap?.parentElement?.closest(".cv-edit-diff__header") === header).toBe(true);
    expect(wrap?.nextElementSibling?.getAttribute("aria-label")).toBe("Copy diff");
    // A visible-text-free icon button names itself by aria-label only (no title tooltip).
    expect(wrap?.hasAttribute("title")).toBe(false);
  }
});

test("the wrap choice holds for every block of its kind and is remembered", async () => {
  await renderDiffs(await newFile("/w/a.md", "a\n"), await newFile("/w/b.txt", "b\n"), await newFile("/w/c.ts", "c\n"));
  await click(wrapOf(card("a.md")));
  expect(wrapOf(card("a.md"))?.getAttribute("aria-pressed")).toBe("false");
  expect(wrapOf(card("b.txt"))?.getAttribute("aria-pressed")).toBe("false");
  expect(wrapOf(card("c.ts"))?.getAttribute("aria-pressed")).toBe("false");
  await click(wrapOf(card("c.ts")));
  expect(wrapOf(card("c.ts"))?.getAttribute("aria-pressed")).toBe("true");
  expect(wrapOf(card("a.md"))?.getAttribute("aria-pressed")).toBe("false");
  // A new page (another chat tab) starts from the remembered choices.
  act(() => root?.unmount());
  root = undefined;
  await renderDiffs(await newFile("/w/d.md", "d\n"), await newFile("/w/e.ts", "e\n"));
  expect(wrapOf(card("d.md"))?.getAttribute("aria-pressed")).toBe("false");
  expect(wrapOf(card("e.ts"))?.getAttribute("aria-pressed")).toBe("true");
});

test("a diff longer than eight lines shows its first lines under a fade, with Show all N lines", async () => {
  await renderDiffs(await newFile("/w/notes.md", lines(21)), await newFile("/w/short.ts", lines(5)));
  const long = card("notes.md");
  expect(long.querySelector(".cv-edit-diff__body")?.getAttribute("data-preview")).toBe("cut");
  const more = byText("Show all 21 lines", long);
  expect(more?.getAttribute("aria-expanded")).toBe("false");
  await click(more);
  expect(long.querySelector(".cv-edit-diff__body")?.getAttribute("data-preview")).toBe("all");
  expect(byText("Show less", long)?.getAttribute("aria-expanded")).toBe("true");
  // Five lines show whole, with nothing to open.
  const short = card("short.ts");
  expect(short.querySelector(".cv-edit-diff__body")?.hasAttribute("data-preview")).toBe(false);
  expect(buttons(short).some((node) => node.textContent?.startsWith("Show all"))).toBe(false);
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

test("a Shell block previews eight lines under a fade and wraps its output with a hanging indent", async () => {
  await openRow(
    "execute",
    lines(30, (index) => `case ${index + 1} ${"ok ".repeat(40)}`),
    "bun test",
  );
  const shell = host.querySelector(".cv-shell")!;
  const body = shell.querySelector(".cv-shell__body")!;
  expect(body.getAttribute("data-preview")).toBe("cut");
  // The command line and the thirty lines of output.
  const more = byText("Show all 31 lines", shell);
  expect(Boolean(more)).toBe(true);
  // Output wraps by default, each line its own block so a wrapped line hangs under its start.
  const wrap = wrapOf(shell);
  expect(Boolean(wrap?.closest(".cv-shell__label"))).toBe(true);
  expect(wrap?.getAttribute("aria-pressed")).toBe("true");
  expect(body.getAttribute("data-wrap")).toBe("true");
  expect(shell.querySelectorAll(".cv-shell__output .cv-line").length).toBe(30);
  // Copy and Find still read the output's exact text.
  expect(shell.querySelector(".cv-shell__output")?.textContent).toBe(
    lines(30, (index) => `case ${index + 1} ${"ok ".repeat(40)}`).replace(/\n$/, ""),
  );
  await click(more);
  expect(body.getAttribute("data-preview")).toBe("all");
  await click(wrap);
  expect(body.getAttribute("data-wrap")).toBe("false");
});

test("a long output's preview counts all its lines, not only the end it shows, and opens all of it", async () => {
  await openRow("execute", lines(1000), "seq 1000");
  const shell = host.querySelector(".cv-shell")!;
  // The command line and all thousand lines, though only the last 400 are drawn until opened.
  expect(Boolean(byText("Show all 401 lines", shell))).toBe(false);
  expect(Boolean(byText("Show all output", shell))).toBe(false);
  await click(byText("Show all 1001 lines", shell));
  expect(shell.querySelector(".cv-shell__output")?.textContent).toBe(lines(1000).replace(/\n$/, ""));
  expect(Boolean(byText("Show all output", shell))).toBe(false);
  // Show less closes it up to the preview of its end again.
  await click(byText("Show less", shell));
  expect(shell.querySelector(".cv-shell__body")?.getAttribute("data-preview")).toBe("cut");
  expect(shell.querySelector(".cv-shell__output")?.textContent?.startsWith("line 601\n")).toBe(true);
});

test("an output opened while short stays open as it streams past the tail", async () => {
  const { ToolRow } = await import("../src/agent-session/acpmux/conversation/ToolRow");
  await render(<ToolRow item={call("execute", lines(20), "bun test")} />);
  await click(host.querySelector("button.cv-tool"));
  await click(byText("Show all 21 lines"));
  // The stream goes on past the 400 lines a closed output draws the end of.
  await act(async () => root!.render(<ToolRow item={call("execute", lines(1000), "bun test")} />));
  const shell = host.querySelector(".cv-shell")!;
  expect(shell.querySelector(".cv-shell__output")?.textContent).toBe(lines(1000).replace(/\n$/, ""));
  expect(Boolean(byText("Show less", shell))).toBe(true);
  // Show less closes it up to the end of the output.
  await click(byText("Show less", shell));
  expect(shell.querySelector(".cv-shell__output")?.textContent?.startsWith("line 601\n")).toBe(true);
  expect(Boolean(byText("Show all 1001 lines", shell))).toBe(true);
});

test("Find does not count the preview's Show all and Show less, nor Show all output", async () => {
  await openRow("execute", lines(30), "bun test");
  const shell = host.querySelector(".cv-shell")!;
  const more = byText("Show all 31 lines", shell);
  expect(more?.hasAttribute("data-find-skip")).toBe(true);
  await click(more);
  expect(byText("Show less", shell)?.hasAttribute("data-find-skip")).toBe(true);
  act(() => root?.unmount());
  // A tail cut in one long line: too few lines for a preview, so Show all output stands alone.
  await openRow("execute", "x".repeat(50_000), "yes x");
  expect(byText("Show all output")?.hasAttribute("data-find-skip")).toBe(true);
});

test("Find in Chat opens a cut diff whose match lies past its first lines", async () => {
  const { FindReveal } = await import("../src/agent-session/acpmux/conversation/chatFind");
  const { EditDiff } = await import("../src/agent-session/acpmux/conversation/EditDiff");
  const file = await newFile("/w/notes.md", lines(21));
  const reveal = (needle: string) => ({ rowId: "row-1", card: false, needle, repaint: () => {} });
  await render(
    <FindReveal.Provider value={reveal("line 15")}>
      <EditDiff file={file} />
    </FindReveal.Provider>,
  );
  expect(host.querySelector(".cv-edit-diff__body")?.getAttribute("data-preview")).toBe("all");
  act(() => root?.unmount());
  // A match the diff does not hold leaves it cut.
  await render(
    <FindReveal.Provider value={reveal("not in this file")}>
      <EditDiff file={file} />
    </FindReveal.Provider>,
  );
  expect(host.querySelector(".cv-edit-diff__body")?.getAttribute("data-preview")).toBe("cut");
});

test("a diff Find reveals through its row opens past the cut too", async () => {
  const { EditDiff } = await import("../src/agent-session/acpmux/conversation/EditDiff");
  const file = await newFile("/w/notes.md", lines(21));
  // As ToolRow passes it: bumped each time Find reveals the row.
  const closed = { file, reveal: 0 };
  const revealed = { file, reveal: 1 };
  await render(<EditDiff {...closed} />);
  expect(host.querySelector(".cv-edit-diff__body")?.getAttribute("data-preview")).toBe("cut");
  await act(async () => root!.render(<EditDiff {...revealed} />));
  expect(host.querySelector(".cv-edit-diff__body")?.getAttribute("data-preview")).toBe("all");
});

test("a call's output has Wrap lines and the same preview", async () => {
  await openRow("fetch", lines(12));
  const card = host.querySelector(".cv-tool-output-card")!;
  expect(wrapOf(card)?.getAttribute("aria-pressed")).toBe("true");
  expect(card.querySelector(".cv-tool-output")?.getAttribute("data-preview")).toBe("cut");
  expect(Boolean(byText("Show all 12 lines", card))).toBe(true);
});

test("a box wider than its content area marks its right edge until scrolled to the end, inside shadow roots too", async () => {
  const { watchSideways, MORE_RIGHT } = await import("../src/agent-session/acpmux/conversation/sideways");
  const box = window.document.createElement("pre");
  host.append(box);
  const size = (element: Element, scrollWidth: number, clientWidth: number) => {
    Object.defineProperty(element, "scrollWidth", { configurable: true, get: () => scrollWidth });
    Object.defineProperty(element, "clientWidth", { configurable: true, get: () => clientWidth });
  };
  size(box, 900, 300);
  // Pierre draws a diff's rows in a shadow root, where its `[data-code]` scrolls sideways.
  const pierre = window.document.createElement("div");
  box.append(pierre);
  const shadow = pierre.attachShadow({ mode: "open" });
  const code = window.document.createElement("div");
  code.setAttribute("data-code", "");
  shadow.append(code);
  size(code, 1200, 300);
  const stop = watchSideways(box);
  try {
    expect(box.hasAttribute(MORE_RIGHT)).toBe(true);
    expect(code.hasAttribute(MORE_RIGHT)).toBe(true);
    box.scrollLeft = 600;
    box.dispatchEvent(new window.Event("scroll"));
    expect(box.hasAttribute(MORE_RIGHT)).toBe(false);
    code.scrollLeft = 900;
    code.dispatchEvent(new window.Event("scroll"));
    expect(code.hasAttribute(MORE_RIGHT)).toBe(false);
  } finally {
    stop();
    box.remove();
  }
});

test("the cuts are fades, a wrapped line hangs, and Pierre's rows get both", async () => {
  const css = readFileSync(
    path.join(import.meta.dir, "../src/agent-session/acpmux/conversation/conversation.css"),
    "utf8",
  );
  // Every declaration block of the rules whose selector has `selector`.
  const rule = (selector: RegExp) =>
    [...css.matchAll(new RegExp(`${selector.source}[^{]*\\{([^}]*)\\}`, "g"))].map((match) => match[1]).join("\n");
  // The preview's bottom edge and the overflow's right edge fade out (a mask), never a hard edge.
  expect(rule(/\[data-preview="cut"\]/)).toMatch(/--cv-fade-bottom:\s*\d/);
  expect(rule(/\[data-more-right\]/)).toMatch(/--cv-fade-right:\s*\d/);
  expect(css).toMatch(/mask-image:\s*linear-gradient\(to bottom[^;]*var\(--cv-fade-bottom/);
  expect(css).toMatch(/linear-gradient\(to left[^;]*var\(--cv-fade-right/);
  // A wrapped line hangs: its second row starts further in than its first.
  expect(rule(/\[data-wrap="true"\] \.cv-line/)).toMatch(/text-indent:\s*-/);
  const { PIERRE_BLOCK_CSS } = await import("../src/agent-session/acpmux/conversation/sideways");
  expect(PIERRE_BLOCK_CSS).toMatch(/\[data-overflow="?wrap"?\] \[data-line\][^{]*\{[^}]*text-indent:\s*-/);
  expect(PIERRE_BLOCK_CSS).toMatch(/\[data-more-right\][^{]*\{[^}]*mask-image/);
});
