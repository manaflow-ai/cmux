// l10n-allow-file: test fixture paths, commands and file text, not shipped UI.
// Tool-call blocks in the agent chat (Leo 2026-10-21, "Edited codex-excursions.md +21 -0"): a long
// line ran off the block's right edge with no scrollbar and no sign there was more, a long block
// was a 240px box with a hard bottom edge, and there was no way to wrap.
//
// Now: a prose file (md, txt) wraps with a hanging indent by default and code stays on one line,
// with a fade at the right edge while more of it lies past it. Each block's header has Wrap lines
// beside Copy, remembered per kind of block (prose, code, output). Every line is drawn, in a box that
// scrolls inside past 24 lines (outputScrollBox.css), never behind a Show all button (Leo,
// 2026-11-12: "i think [another chat app] just lets you scroll, straight up?"). The same holds for a command's
// Shell block and a call's output.
import { afterAll, afterEach, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { teardownDom } from "./support/domTeardown";

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

afterAll(async () => {
  for (const key of added) delete scope[key];
  await teardownDom(saved, { scope });
});

async function render(node: React.ReactNode) {
  const { createRoot } = await import("react-dom/client");
  // Each mount starts from no reader choices: a call's open state is kept by its id past an unmount
  // (transcriptDisclosureModel.ts useRowDisclosure), and these fixtures reuse their call ids.
  const { resetTranscriptDisclosure } =
    await import("../src/agent-session/acpmux/conversation/transcriptDisclosureModel");
  resetTranscriptDisclosure();
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
    // It changes its block's height, so the transcript holds it in place while it lays out
    // (foldAnchor.ts), unlike a reply's Pin or Read aloud.
    const { FOLD_TOGGLE } = await import("../src/agent-session/acpmux/conversation/foldAnchor");
    expect(wrap?.matches(FOLD_TOGGLE)).toBe(true);
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

test("a diff of any length sits in the shared scroll box, with nothing to open", async () => {
  await renderDiffs(await newFile("/w/notes.md", lines(60)), await newFile("/w/short.ts", lines(5)));
  for (const name of ["notes.md", "short.ts"]) {
    const block = card(name);
    expect(block.querySelector(".cv-edit-diff__body")?.classList.contains("cv-scroll-box")).toBe(true);
    expect(buttons(block).some((node) => /^Show (all|less)/.test(node.textContent ?? ""))).toBe(false);
  }
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

test("a Shell block scrolls its output in the shared box and wraps its long lines down, each line its own block", async () => {
  await openRow(
    "execute",
    lines(30, (index) => `case ${index + 1} ${"ok ".repeat(40)}`),
    "bun test",
  );
  const shell = host.querySelector(".cv-shell")!;
  const body = shell.querySelector(".cv-shell__body")!;
  expect(body.classList.contains("cv-scroll-box")).toBe(true);
  expect(buttons(shell).some((node) => /^Show (all|less)/.test(node.textContent ?? ""))).toBe(false);
  // Output that is not a table wraps down (blockWrap.ts `outputWraps`; Leo, 2026-11-11: "it goes
  // down instead of to the right"): each line its own block, a long one hanging under its start.
  // Wrap lines keeps the long rows whole, the body scrolling sideways for what runs past.
  const wrap = wrapOf(shell);
  expect(Boolean(wrap?.closest(".cv-shell__label"))).toBe(true);
  expect(wrap?.getAttribute("aria-pressed")).toBe("true");
  expect(body.getAttribute("data-wrap")).toBe("true");
  expect(shell.querySelectorAll(".cv-shell__output .cv-line").length).toBe(30);
  // Copy and Find still read the output's exact text.
  expect(shell.querySelector(".cv-shell__output")?.textContent).toBe(
    lines(30, (index) => `case ${index + 1} ${"ok ".repeat(40)}`).replace(/\n$/, ""),
  );
  await click(wrap);
  expect(body.getAttribute("data-wrap")).toBe("false");
});

test("a Shell block's table keeps each row whole, its columns aligned", async () => {
  const ps = [
    "  PID TTY           TIME CMD",
    ...Array.from(
      { length: 4 },
      (_, index) => ` ${4821 + index} ttys00${index}    0:00.1${index} ${"node vite ".repeat(12)}`,
    ),
  ].join("\n");
  await openRow("execute", ps, "ps");
  const body = host.querySelector(".cv-shell .cv-shell__body")!;
  expect(body.getAttribute("data-wrap")).toBe("false");
});

test("a long output draws every line, and a huge one its end, in the scroll box", async () => {
  await openRow("execute", lines(1000), "seq 1000");
  const shell = host.querySelector(".cv-shell")!;
  expect(shell.querySelector(".cv-shell__output")?.textContent).toBe(lines(1000).replace(/\n$/, ""));
  act(() => root?.unmount());
  // Past 2,000 lines only the end is drawn, so a megabyte never stalls the pane; Find draws it all.
  await openRow("execute", lines(5000), "seq 5000");
  const huge = host.querySelector(".cv-shell")!;
  expect(huge.querySelector(".cv-shell__output")?.textContent?.startsWith("line 3001\n")).toBe(true);
  expect(buttons(huge).some((node) => /^Show (all|less)/.test(node.textContent ?? ""))).toBe(false);
});

test("Find in Chat draws all of a huge output, its head too", async () => {
  const { ShellBlock } = await import("../src/agent-session/acpmux/conversation/ShellBlock");
  await render(<ShellBlock command="seq 5000" output={lines(5000)} reveal={1} />);
  expect(host.querySelector(".cv-shell__output")?.textContent?.startsWith("line 1\n")).toBe(true);
});

test("a call's output has Wrap lines and the same scroll box", async () => {
  await openRow("other", lines(12));
  const card = host.querySelector(".cv-tool-output-card")!;
  // Plain lines are not a table, so they wrap down (blockWrap.ts `outputWraps`).
  expect(wrapOf(card)?.getAttribute("aria-pressed")).toBe("true");
  expect(card.querySelector(".cv-tool-output")?.classList.contains("cv-scroll-box")).toBe(true);
  expect(buttons(card).some((node) => /^Show (all|less)/.test(node.textContent ?? ""))).toBe(false);
});

test("a box wider than its content area marks its right edge until scrolled to the end, inside shadow roots too", async () => {
  const { watchSideways, MORE_RIGHT } = await import("../src/agent-session/acpmux/conversation/sideways");
  const { SIDEWAYS_ATTRIBUTE } = await import("../src/scrollers");
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
  // A box whose lines fit marks neither.
  const fits = window.document.createElement("pre");
  box.append(fits);
  size(fits, 300, 300);
  const stop = watchSideways(box);
  const stopFits = watchSideways(fits);
  try {
    expect(box.hasAttribute(MORE_RIGHT)).toBe(true);
    expect(code.hasAttribute(MORE_RIGHT)).toBe(true);
    // Both scroll sideways, so both keep their thumb at rest (scrollers.ts SIDEWAYS_ATTRIBUTE).
    expect([box.hasAttribute(SIDEWAYS_ATTRIBUTE), code.hasAttribute(SIDEWAYS_ATTRIBUTE)]).toEqual([true, true]);
    expect([fits.hasAttribute(MORE_RIGHT), fits.hasAttribute(SIDEWAYS_ATTRIBUTE)]).toEqual([false, false]);
    box.scrollLeft = 600;
    box.dispatchEvent(new window.Event("scroll"));
    expect(box.hasAttribute(MORE_RIGHT)).toBe(false);
    code.scrollLeft = 900;
    code.dispatchEvent(new window.Event("scroll"));
    expect(code.hasAttribute(MORE_RIGHT)).toBe(false);
    // Scrolled to the end they still scroll: the thumb stays.
    expect([box.hasAttribute(SIDEWAYS_ATTRIBUTE), code.hasAttribute(SIDEWAYS_ATTRIBUTE)]).toEqual([true, true]);
  } finally {
    stopFits();
    stop();
    box.remove();
  }
});

test("a token streamed into one block of a long transcript measures that block once a frame, never the others", async () => {
  const { watchSideways } = await import("../src/agent-session/acpmux/conversation/sideways");
  const document = window.document;
  // A transcript of many blocks of many lines, each watched as BlockParts.tsx does, one of them
  // with Pierre's shadow root (a diff), counting every width read and every element walked.
  const BLOCKS = 200;
  const LINES = 20;
  const reads = new Map<Element, number>();
  const counted = (element: Element, scrollWidth: number, clientWidth: number) => {
    const read = (value: number) => () => (reads.set(element, (reads.get(element) ?? 0) + 1), value);
    Object.defineProperty(element, "scrollWidth", { configurable: true, get: read(scrollWidth) });
    Object.defineProperty(element, "clientWidth", { configurable: true, get: read(clientWidth) });
  };
  const transcript = document.createElement("div");
  host.append(transcript);
  const bodies: HTMLElement[] = [];
  for (let block = 0; block < BLOCKS; block++) {
    const body = document.createElement("pre");
    for (let line = 0; line < LINES; line++) {
      const span = document.createElement("span");
      span.className = "cv-line";
      span.textContent = `line ${line}`;
      body.append(span);
    }
    counted(body, 300, 300);
    transcript.append(body);
    bodies.push(body);
  }
  // A custom element of its own: the earlier tests' Pierre defines `diffs-container`, which makes
  // its own shadow root.
  const diff = document.createElement("cmux-test-diff");
  bodies[3]!.append(diff);
  const code = document.createElement("div");
  code.setAttribute("data-code", "");
  for (let line = 0; line < LINES; line++) code.append(document.createElement("div"));
  diff.attachShadow({ mode: "open" }).append(code);
  counted(code, 300, 300);
  const stops = bodies.map((body) => watchSideways(body));
  const walked = { elements: 0 };
  const queryAll = window.Element.prototype.querySelectorAll;
  const queryAllFragment = window.DocumentFragment.prototype.querySelectorAll;
  try {
    window.Element.prototype.querySelectorAll = function (this: Element, selectors: string) {
      const found = queryAll.call(this, selectors);
      walked.elements += found.length;
      return found;
    } as typeof queryAll;
    window.DocumentFragment.prototype.querySelectorAll = function (this: DocumentFragment, selectors: string) {
      const found = queryAllFragment.call(this, selectors);
      walked.elements += found.length;
      return found;
    } as typeof queryAllFragment;
    reads.clear();
    const streamed = bodies[100]!;
    const line = streamed.children[LINES - 1]!;
    const nextFrame = () => new Promise((resolve) => window.requestAnimationFrame(resolve));
    // Fifty tokens, each its own change, inside one frame: nothing is measured yet.
    for (let token = 0; token < 50; token++) {
      line.append(document.createTextNode(` token${token}`));
      await Promise.resolve();
      await Promise.resolve();
    }
    const duringStream = reads.size;
    await nextFrame();
    await nextFrame();
    const measured = [...reads.keys()].map((element) => bodies.indexOf(element as HTMLElement));
    expect({ duringStream, measured }).toEqual({ duringStream: 0, measured: [100] });
    // Once (both widths) for the fifty tokens.
    expect(reads.get(streamed)).toBeLessThanOrEqual(4);
    // No token walks the block's lines, nor any other block's.
    expect(walked.elements).toBeLessThan(LINES);
    // A token in the diff's shadow root measures only the diff's code box.
    reads.clear();
    code.lastElementChild!.append(document.createTextNode(" token"));
    await Promise.resolve();
    await nextFrame();
    await nextFrame();
    expect([...reads.keys()]).toEqual([code]);
  } finally {
    window.Element.prototype.querySelectorAll = queryAll;
    window.DocumentFragment.prototype.querySelectorAll = queryAllFragment;
    for (const stop of stops) stop();
    transcript.remove();
  }
});

test("a Pierre host removed from a block takes its shadow root's watching with it, and stop ends the rest", async () => {
  const { watchSideways } = await import("../src/agent-session/acpmux/conversation/sideways");
  const document = window.document;
  const page = window as unknown as Record<string, unknown>;
  // What the watcher holds, counted: scroll listeners, boxes the size observer watches, roots the
  // change observers watch, and every width read of a detached box.
  const listeners = { scroll: 0 };
  const sized = new Set<{ targets: Set<Element>; callback: (entries: { target: Element }[]) => void }>();
  const roots = new Set<Set<Node>>();
  const detachedReads = { count: 0 };
  const held = () => ({
    scroll: listeners.scroll,
    sized: [...sized].reduce((sum, { targets }) => sum + targets.size, 0),
    roots: [...roots].reduce((sum, targets) => sum + targets.size, 0),
  });
  const Mutations = window.MutationObserver;
  const add = window.EventTarget.prototype.addEventListener;
  const remove = window.EventTarget.prototype.removeEventListener;
  // Pierre drawing into a host resizes it.
  const resized = (target: Element) => {
    for (const { targets, callback } of sized) if (targets.has(target)) callback([{ target }]);
  };
  page.ResizeObserver = class {
    targets = new Set<Element>();
    constructor(callback: (entries: { target: Element }[]) => void) {
      sized.add({ targets: this.targets, callback });
    }
    observe(target: Element) {
      this.targets.add(target);
    }
    unobserve(target: Element) {
      this.targets.delete(target);
    }
    disconnect() {
      this.targets.clear();
    }
  };
  page.MutationObserver = class {
    inner: MutationObserver;
    targets = new Set<Node>();
    constructor(callback: MutationCallback) {
      this.inner = new Mutations(callback);
      roots.add(this.targets);
    }
    observe(target: Node, options: MutationObserverInit) {
      this.inner.observe(target, options);
      this.targets.add(target);
    }
    disconnect() {
      this.inner.disconnect();
      this.targets.clear();
    }
  };
  type Listener = EventListenerOrEventListenerObject | null;
  window.EventTarget.prototype.addEventListener = function (
    this: EventTarget,
    type: string,
    listener: Listener,
    options?: boolean | AddEventListenerOptions,
  ) {
    if (type === "scroll") listeners.scroll++;
    add.call(this, type, listener, options);
  } as typeof add;
  window.EventTarget.prototype.removeEventListener = function (
    this: EventTarget,
    type: string,
    listener: Listener,
    options?: boolean | EventListenerOptions,
  ) {
    if (type === "scroll") listeners.scroll--;
    remove.call(this, type, listener, options);
  } as typeof remove;
  const nextFrame = () => new Promise((resolve) => window.requestAnimationFrame(resolve));
  const settle = async () => {
    await Promise.resolve();
    await Promise.resolve();
    await nextFrame();
  };
  const body = document.createElement("pre");
  host.append(body);
  let stop: (() => void) | undefined;
  try {
    stop = watchSideways(body);
    const mounted = held();
    for (let round = 0; round < 6; round++) {
      // Pierre's host, its shadow root attached before it is drawn in or after (every other round).
      const pierre = document.createElement("cmux-test-pierre");
      const code = document.createElement("div");
      code.setAttribute("data-code", "");
      code.append(document.createElement("div"));
      for (const name of ["scrollWidth", "clientWidth"] as const)
        Object.defineProperty(code, name, {
          configurable: true,
          get: () => {
            if (!code.isConnected) detachedReads.count++;
            return name === "scrollWidth" ? 900 : 300;
          },
        });
      if (round % 2 === 0) pierre.attachShadow({ mode: "open" }).append(code);
      body.append(pierre);
      await settle();
      if (round % 2 === 1) {
        pierre.attachShadow({ mode: "open" }).append(code);
        resized(pierre);
        await settle();
      }
      expect(held()).toEqual({ scroll: mounted.scroll + 1, sized: mounted.sized + 2, roots: mounted.roots + 1 });
      pierre.remove();
      await settle();
      // Pierre redraws the detached root: nothing measures it.
      code.append(document.createElement("div"));
      await settle();
      expect({ round, ...held(), detachedReads: detachedReads.count }).toEqual({
        round,
        ...mounted,
        detachedReads: 0,
      });
    }
    // A host removed before its shadow root comes is let go too.
    const late = document.createElement("cmux-test-pierre");
    body.append(late);
    await settle();
    late.remove();
    await settle();
    expect(held()).toEqual(mounted);
    stop();
    stop = undefined;
    expect(held()).toEqual({ scroll: 0, sized: 0, roots: 0 });
  } finally {
    stop?.();
    delete page.ResizeObserver;
    page.MutationObserver = Mutations;
    window.EventTarget.prototype.addEventListener = add;
    window.EventTarget.prototype.removeEventListener = remove;
    body.remove();
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
  expect(rule(/\[data-more-below\]/)).toMatch(/--cv-fade-bottom:\s*\d/);
  expect(rule(/\[data-more-right\]/)).toMatch(/--cv-fade-right:\s*\d/);
  expect(css).toMatch(/mask-image:\s*linear-gradient\(\s*to bottom[^;]*var\(--cv-fade-bottom/);
  // The fade ends above the sideways scrollbar's lane, and the bar in it stays opaque.
  expect(css).toMatch(
    /linear-gradient\(\s*to bottom[^;]*transparent calc\(100% - var\(--cv-lane[^;]*#000 calc\(100% - var\(--cv-bar/,
  );
  expect(css).toMatch(/linear-gradient\(to left[^;]*var\(--cv-fade-right/);
  // A wrapped line hangs: its second row starts further in than its first.
  expect(rule(/\[data-wrap="true"\] \.cv-line/)).toMatch(/text-indent:\s*-/);
  const { PIERRE_BLOCK_CSS } = await import("../src/agent-session/acpmux/conversation/sideways");
  expect(PIERRE_BLOCK_CSS).toMatch(/\[data-overflow="?wrap"?\] \[data-line\][^{]*\{[^}]*text-indent:\s*-/);
  expect(PIERRE_BLOCK_CSS).toMatch(/\[data-more-right\][^{]*\{[^}]*mask-image/);
});
