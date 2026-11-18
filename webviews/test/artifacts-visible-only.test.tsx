// The Artifacts page's history and a revision's change draw what is visible (the visible-only rule).
// A file's first revision is every line added: at 1,000 and 10,000 lines the change mounts the same
// lines and DOM nodes, and a one-line scroll draws only the lines it brings in. The history (at most
// HISTORY_LIMIT revisions, so every row mounts) draws again only the rows a choice moves between,
// and a refresh that reads the same history and change draws none. Before, every line of the change
// was a mounted row keyed by its index, and every revision's row drew on each store update.
// A copy across lines that are not mounted still copies them, read from the model.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { PageClient } from "../src/pages/shared/pageClient";
import { ArtifactsOps, type ArtifactCommit } from "../src/pages/artifacts/types";
import { settleReact } from "./support/domTeardown";
import { mountedRowRenders } from "./support/mountedRowRenders";
import { installVirtualSizes } from "./support/virtualSizes";

const scope = globalThis as Record<string, unknown>;
const names = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "HTMLTemplateElement",
  "customElements",
  "Element",
  "Node",
  "MouseEvent",
  "KeyboardEvent",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
const saved = names.map((name) => [name, scope[name]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

/** The history pane is 280 px tall, as are the tree's; a diff line is 14 px, a tree row 26. */
const PANE = 280;
const LINE = 14;
const sizes = (element: HTMLElement) =>
  element.classList.contains("artifacts-history") || element.classList.contains("artifacts-scroll")
    ? PANE
    : element.classList.contains("artifacts-line")
      ? LINE
      : element.classList.contains("artifacts-row")
        ? 26
        : 0;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/artifacts/",
    pretendToBeVisual: true,
  });
  const win = dom.window as unknown as Record<string, unknown>;
  for (const name of names) scope[name] = name === "window" ? dom.window : win[name];
  scope.IS_REACT_ACT_ENVIRONMENT = true;
  scope.getComputedStyle = dom.window.getComputedStyle.bind(dom.window);
  scope.requestAnimationFrame = (callback: FrameRequestCallback) =>
    setTimeout(() => callback(Date.now()), 0) as unknown as number;
  scope.cancelAnimationFrame = (handle: number) => clearTimeout(handle);
  // The page's stylesheet is not loaded: the panes scroll as styles.css says.
  const style = dom.window.document.createElement("style");
  style.textContent =
    ".artifacts-history, .artifacts-scroll { overflow-y: auto; } .artifacts-diff { overflow-x: auto; }";
  dom.window.document.head.append(style);
  installVirtualSizes(dom.window, sizes);
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
});

afterAll(async () => {
  await settleReact();
  dom.window.close();
  for (const [name, value] of saved) {
    if (value === undefined) delete scope[name];
    else scope[name] = value;
  }
});

const { createRoot } = await import("react-dom/client");
const { ArtifactsPage } = await import("../src/pages/artifacts/ArtifactsPage");
const { ArtifactsStore, HISTORY_LIMIT } = await import("../src/pages/artifacts/store");
const { createStrings } = await import("../src/pages/shared/i18n");
const table = (await import("../src/pages/artifacts/generated/strings.json")).default as Record<
  string,
  Record<string, string>
>;

const sha = (index: number) => index.toString(16).padStart(40, "0");
const PATH = "notes/big.md";

/** One file of `n` lines whose newest revision has no parent (every line added), and older ones. */
function bigHost(n: number): PageClient {
  const text = Array.from({ length: n }, (_, index) => `line ${index}`).join("\n") + "\n";
  const commits: ArtifactCommit[] = Array.from({ length: HISTORY_LIMIT }, (_, index) => ({
    sha: sha(index + 1),
    parents: [],
    message: `Revision ${index}`,
    authorName: "cmux",
    time: Date.UTC(2026, 10, 18) - index * 60_000,
    // Shown as "claude · bench": text with spaces just above the change.
    trailers: { harness: "claude", machine: "bench" },
  }));
  return {
    call: async <R,>(op: string, params: unknown): Promise<R> => {
      const { ref } = (params ?? {}) as { ref?: string };
      if (op === ArtifactsOps.tree)
        return { ref: "main", sha: sha(1), entries: [{ name: "big.md", path: PATH, type: "blob" }] } as R;
      if (op === ArtifactsOps.history) return { commits: commits.map((commit) => ({ ...commit })) } as R;
      return { path: PATH, size: text.length, contentType: "text/markdown", commit: ref ?? sha(1), content: text } as R;
    },
    subscribe: async () => () => {},
    handle: () => () => {},
  };
}

const settle = () => act(async () => new Promise((resolve) => setTimeout(resolve, 0)));

async function mount(n: number) {
  const store = new ArtifactsStore(bigHost(n));
  host = dom.window.document.getElementById("root")!;
  root = createRoot(host);
  await act(async () => root!.render(<ArtifactsPage store={store} strings={createStrings(table, ["en"])} />));
  await act(async () => store.start());
  await settle();
  return { store, pane: host.querySelector<HTMLElement>(".artifacts-history")! };
}

const lines = () => host.querySelectorAll(".artifacts-line");
// The nearest component above each row's node: the row itself once memoized, the list before.
const lineRenders = mountedRowRenders(lines);
const commitRenders = mountedRowRenders(() => host.querySelectorAll(".artifacts-commit"));

async function measure(n: number) {
  const { store, pane } = await mount(n);
  const diff = host.querySelector<HTMLElement>(".artifacts-diff")!;
  const mounted = { lines: lines().length, nodes: diff.querySelectorAll("*").length };

  const rects = { calls: 0 };
  const original = dom.window.Element.prototype.getBoundingClientRect;
  dom.window.Element.prototype.getBoundingClientRect = function (this: Element) {
    rects.calls++;
    return original.call(this);
  };
  lineRenders.mark();
  commitRenders.mark();
  await act(async () => {
    pane.scrollTop += LINE;
    pane.dispatchEvent(new dom.window.Event("scroll"));
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
  const scroll = { lines: lineRenders.since(), commits: commitRenders.since(), rects: rects.calls };
  dom.window.Element.prototype.getBoundingClientRect = original;

  // A refresh at the same head that reads the same history and change.
  lineRenders.mark();
  commitRenders.mark();
  await act(async () => store.select(PATH, true));
  await settle();
  const refresh = { lines: lineRenders.since(), commits: commitRenders.since() };

  // Choosing the third revision: the row it leaves and the row it takes.
  commitRenders.mark();
  await act(async () => host.querySelectorAll<HTMLElement>(".artifacts-commit-button")[2]!.click());
  await settle();
  const choose = commitRenders.since();
  return { n, mounted, scroll, refresh, choose };
}

test("a change of 1,000 and 10,000 lines mounts the same lines, and one event draws only the rows it changed", async () => {
  const small = await measure(1_000);
  act(() => root?.unmount());
  const large = await measure(10_000);
  console.log(JSON.stringify({ small, large }));

  // Rule 1: the pane's lines (280 / 14) and about one viewport each side, not the change.
  for (const run of [small, large]) {
    expect(run.mounted.lines).toBeGreaterThan(10);
    expect(run.mounted.lines).toBeLessThanOrEqual(80);
  }
  expect(Math.abs(large.mounted.lines - small.mounted.lines)).toBeLessThanOrEqual(small.mounted.lines * 0.1);
  expect(Math.abs(large.mounted.nodes - small.mounted.nodes)).toBeLessThanOrEqual(small.mounted.nodes * 0.1);

  for (const run of [small, large]) {
    // Rule 2: a one-line scroll draws only the line it brings in, and no revision's row.
    expect(run.scroll.lines).toBeLessThanOrEqual(2);
    expect(run.scroll.commits).toBe(0);
    // A refresh that reads the same history and change draws nothing again.
    expect(run.refresh.lines).toBe(0);
    expect(run.refresh.commits).toBe(0);
    // Choosing a revision draws the row it leaves and the row it takes.
    expect(run.choose).toBeLessThanOrEqual(2);
  }
  // Rule 3: a scroll reads no row's layout, at any length.
  expect(large.scroll.rects).toBe(small.scroll.rects);
});

test("a copy across lines that are not mounted copies them from the change", async () => {
  await mount(1_000);
  const rows = [...lines()] as HTMLElement[];
  const first = rows[0]!;
  const last = rows.at(-1)!;
  expect(Number(last.dataset.index)).toBeLessThan(999);
  // From "ne 0" on the first line (after its sign and "li") to the very end of the change (the commits below are none).
  const range = dom.window.document.createRange();
  range.setStart(first.childNodes[1]!, 2);
  range.setEndAfter(host.querySelector(".artifacts-diff-lines")!);
  const selection = dom.window.getSelection()!;
  selection.removeAllRanges();
  selection.addRange(range);
  let copied = "";
  const event = new dom.window.Event("copy", { bubbles: true, cancelable: true }) as Event & {
    clipboardData: { setData(type: string, text: string): void };
  };
  event.clipboardData = { setData: (_type, text) => (copied = text) };
  dom.window.document.dispatchEvent(event);
  expect(event.defaultPrevented).toBe(true);
  const expected = Array.from({ length: 1_000 }, (_, index) => `+line ${index}`).join("\n");
  expect(copied).toBe(expected.slice(3));

  // A selection inside the mounted lines is the browser's to copy, as before.
  range.setStart(rows[1]!.childNodes[1]!, 0);
  range.setEnd(rows[3]!.childNodes[1]!, 4);
  const inside = new dom.window.Event("copy", { bubbles: true, cancelable: true });
  dom.window.document.dispatchEvent(inside);
  expect(inside.defaultPrevented).toBe(false);
});

test("the line a selection starts on stays mounted while the pane scrolls far past it", async () => {
  const { pane } = await mount(1_000);
  const anchor = [...lines()][3] as HTMLElement;
  await act(async () => anchor.dispatchEvent(new dom.window.MouseEvent("pointerdown", { bubbles: true })));
  await act(async () => {
    pane.scrollTop += LINE * 400;
    pane.dispatchEvent(new dom.window.Event("scroll"));
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
  expect(anchor.isConnected).toBe(true);
  expect(lines().length).toBeLessThanOrEqual(81);
  expect(Number((lines()[1] as HTMLElement).dataset.index)).toBeGreaterThan(300);
});

/** What a copy of the document's selection writes, and whether the page took the copy. */
function copySelection(): { text: string; taken: boolean } {
  let text = "";
  const event = new dom.window.Event("copy", { bubbles: true, cancelable: true }) as Event & {
    clipboardData: { setData(type: string, text: string): void };
  };
  event.clipboardData = { setData: (_type, data) => (text = data) };
  dom.window.document.dispatchEvent(event);
  return { text, taken: event.defaultPrevented };
}

function select(range: Range) {
  const selection = dom.window.getSelection()!;
  selection.removeAllRanges();
  selection.addRange(range);
}

test("a copy across lines that are not mounted keeps the spaces the selection starts and ends with", async () => {
  const { pane } = await mount(1_000);
  const line = (index: number) => host.querySelector<HTMLElement>(`.artifacts-line[data-index="${index}"]`)!;
  const commits = host.querySelectorAll(".artifacts-commit");
  const trailers = commits[0]!.querySelector(".artifacts-trailers")!.firstChild!;
  const nextMessage = commits[1]!.querySelector(".artifacts-commit-message")!.firstChild!;
  expect(trailers.textContent).toBe("claude · bench");
  expect(nextMessage.textContent).toBe("Revision 1");
  const added = (from: number, to: number) => Array.from({ length: to - from }, (_, at) => `+line ${from + at}`);

  // From " · bench" (the chosen revision's trailers, above the change) to "+line " of line 500,
  // scrolled into view: lines 1 to 499 around the window are not all mounted. Chromium and WebKit
  // copy this selection with every line mounted as " · bench\n+line 0\n…\n+line 499\n+line ".
  await act(async () => {
    pane.scrollTop = LINE * 480;
    pane.dispatchEvent(new dom.window.Event("scroll"));
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
  expect(line(1)).toBeNull();
  const range = dom.window.document.createRange();
  range.setStart(trailers, "claude".length);
  range.setEnd(line(500).childNodes[1]!, "line ".length);
  select(range);
  const into = copySelection();
  expect(into.taken).toBe(true);
  expect(into.text).toBe([" · bench", ...added(0, 500), "+line "].join("\n"));

  // From " 3" in line 3 to "Revision " (the next revision's message, below the change): both ends'
  // spaces are what the selection holds, as the range reads them.
  await act(async () => {
    pane.scrollTop = 0;
    pane.dispatchEvent(new dom.window.Event("scroll"));
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
  range.setStart(line(3).childNodes[1]!, "line".length);
  range.setEnd(nextMessage, "Revision ".length);
  select(range);
  const out = copySelection();
  expect(out.taken).toBe(true);
  expect(out.text.startsWith(" 3\n+line 4\n")).toBe(true);
  expect(out.text.endsWith("\n+line 999\nRevision ")).toBe(true);
  expect(out.text).toBe([" 3", ...added(4, 1_000), "Revision "].join("\n"));
});

test("a selection made with the keyboard keeps its lines mounted while the pane scrolls far past them, and copies whole", async () => {
  const { pane } = await mount(1_000);
  const row = (index: number) => host.querySelector<HTMLElement>(`.artifacts-line[data-index="${index}"]`);
  const start = row(3)!;
  const end = row(8)!;
  // No pointer: a selection from "ne 3" on line 3 to "+li" on line 8, as Shift and the arrows (or
  // find, or a script) make one. The browser says so with a selectionchange (jsdom too, a task later).
  await act(async () => {
    dom.window.getSelection()!.setBaseAndExtent(start.childNodes[1]!, 2, end.childNodes[1]!, 2);
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
  await act(async () => {
    pane.scrollTop += LINE * 400;
    pane.dispatchEvent(new dom.window.Event("scroll"));
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
  expect(row(5)).toBeNull();
  expect(Number((lines()[2] as HTMLElement).dataset.index)).toBeGreaterThan(300);
  expect(start.isConnected).toBe(true);
  expect(end.isConnected).toBe(true);
  const selection = dom.window.getSelection()!;
  expect(selection.anchorNode).toBe(start.childNodes[1]!);
  expect(selection.focusNode).toBe(end.childNodes[1]!);

  const copied = copySelection();
  expect(copied.taken).toBe(true);
  expect(copied.text).toBe(["ne 3", "+line 4", "+line 5", "+line 6", "+line 7", "+li"].join("\n"));
});

// A press pins its line until the selection says where it is. Each press used to add its line to
// the pinned ones for good: where a click selects nothing (the page unselectable, a press of another
// button) no selection change came to clear them, so every line clicked stayed mounted.
const pinsRows = async (pane: HTMLElement, top: number) =>
  act(async () => {
    pane.scrollTop = top * LINE;
    pane.dispatchEvent(new dom.window.Event("scroll"));
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
const lineAt = (index: number) => host.querySelector<HTMLElement>(`.artifacts-line[data-index="${index}"]`);
/** A press and release on a line; `caret` puts the caret where it pressed, as a selectable page does. */
async function click(index: number, { caret = false, shift = false, char = 2 } = {}) {
  const row = lineAt(index)!;
  await act(async () => {
    row.dispatchEvent(new dom.window.MouseEvent("pointerdown", { bubbles: true, shiftKey: shift }));
    const selection = dom.window.getSelection()!;
    if (shift) selection.extend(row.childNodes[1]!, char);
    else if (caret) selection.setBaseAndExtent(row.childNodes[1]!, char, row.childNodes[1]!, char);
    // The browser says so with a selectionchange, a task later (jsdom too).
    await new Promise((resolve) => setTimeout(resolve, 0));
    row.dispatchEvent(new dom.window.MouseEvent("pointerup", { bubbles: true, shiftKey: shift }));
  });
}
/** The mounted lines outside the window around the line at the pane's top (one viewport, 20 lines, each side). */
const outsideWindow = (top: number) =>
  [...lines()].map((row) => Number((row as HTMLElement).dataset.index)).filter((at) => at < top - 20 || at > top + 40);

for (const caret of [false, true])
  test(`50 clicks on lines far apart that ${caret ? "put the caret" : "select nothing"} leave mounted only the window${caret ? " and the caret's line" : ""}`, async () => {
    const { pane } = await mount(10_000);
    await pinsRows(pane, 9_600);
    const window = lines().length;
    dom.window.getSelection()!.removeAllRanges();
    const clicked: number[] = [];
    for (let at = 0; at < 50; at++) {
      const index = at * 190 + 5;
      await pinsRows(pane, index - 2);
      await click(index, { caret });
      clicked.push(index);
    }
    await pinsRows(pane, 9_600);
    const extra = outsideWindow(9_600);
    console.log(JSON.stringify({ caret, window, mounted: lines().length, extra: extra.length }));
    expect(extra).toEqual(caret ? [clicked.at(-1)!] : []);
    expect(lines().length).toBeLessThanOrEqual(window + (caret ? 1 : 0));
    if (!caret) return;

    // A Shift-click far above extends from the caret, whose line stayed mounted, and copies what it covers.
    const anchor = lineAt(9_315)!;
    await pinsRows(pane, 0);
    expect(anchor.isConnected).toBe(true);
    await click(20, { shift: true, char: 3 });
    const selection = dom.window.getSelection()!;
    expect(selection.anchorNode).toBe(anchor.childNodes[1]!);
    expect(selection.anchorOffset).toBe(2);
    expect(selection.focusNode).toBe(lineAt(20)!.childNodes[1]!);
    expect(outsideWindow(0)).toEqual([9_315]);
    const expected = ["e 20", ...Array.from({ length: 9_315 - 21 }, (_, at) => `+line ${21 + at}`), "+li"].join("\n");
    expect(copySelection().text).toBe(expected);
    // Scrolled far from both ends: both stay mounted, and only they.
    await pinsRows(pane, 5_000);
    expect(outsideWindow(5_000)).toEqual([20, 9_315]);
    expect(copySelection().text).toBe(expected);
  });
