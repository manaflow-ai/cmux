// l10n-allow-file: test fixture prompts, not shipped UI.
// Leo 2026-10-21: a long prompt collapses as Claude's does. A sent prompt longer than ten lines
// shows its first ten, the last ones fading out, with a Show more / Show less toggle under them; the hover
// row stays, and Copy copies the whole prompt. The choice is kept by the row's id (the transcript
// disclosure store), so a prompt scrolled out and back, or drawn again from history, stays as the
// reader left it. A block the composer marked as pasted (`user_message.pasted`, UTF-16 ranges into
// its text) is a chip, "<first words> · N lines", that opens in place. Find opens a collapsed
// prompt or chip that holds the current match.
//
// The browser test (agent-pane-long-prompt.test.ts) measures the drawn height; this one checks the
// structure, the toggle, Copy and the paste ranges.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const copied: string[] = [];
Object.defineProperty(dom.window.navigator, "clipboard", {
  value: { writeText: async (text: string) => void copied.push(text) },
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  customElements: dom.window.customElements,
  MutationObserver: dom.window.MutationObserver,
  NodeFilter: dom.window.NodeFilter,
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (
    /^(HTML|SVG|CSS|Shadow|Document|Mutation|KeyboardEvent|PointerEvent|MouseEvent|FocusEvent)/.test(key) &&
    !(key in scope)
  )
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { UserBubble } = await import("../src/agent-session/acpmux/conversation/UserBubble");
const { foldMotion } = await import("../src/agent-session/acpmux/conversation/fold");
const { FindReveal } = await import("../src/agent-session/acpmux/conversation/chatFind");
const { resetTranscriptDisclosure } = await import("../src/agent-session/acpmux/conversation/transcriptDisclosure");
const { pasteRanges, COLLAPSED_PROMPT_LINES } = await import("../src/agent-session/acpmux/conversation/promptCollapse");
const { paintFindHighlights } = await import("../src/agent-session/acpmux/conversation/chatFind");
const { translate } = await import("../src/agent-session/acpmux/i18n");
// Strings by key (REVIEW.md: tests never pin English copy).
const MORE = translate("message.more");
const LESS = translate("message.less");
const COPY = `.cv-user__actions button[aria-label="${translate("turn.copy")}"]`;

const host = dom.window.document.getElementById("root")!;
let root = createRoot(host);
type Row = Parameters<typeof UserBubble>[0]["row"];
const lines = (count: number, word = "line") =>
  Array.from({ length: count }, (_, index) => `${word} ${index + 1}`).join("\n");
const prompt = (id: string, text: string, extra: Partial<Row> = {}): Row => ({
  id,
  version: 1,
  at: Date.now(),
  kind: "user",
  text,
  ...extra,
});
const render = (row: Row, reveal?: React.ContextType<typeof FindReveal>) =>
  act(() =>
    root.render(
      <FindReveal.Provider value={reveal}>
        <article data-row-id={row.id}>
          <UserBubble row={row} text={row.text ?? ""} />
        </article>
      </FindReveal.Provider>,
    ),
  );
/// Unmounts and mounts again, as the virtualized transcript does for a row scrolled out and back.
const remount = (row: Row) => {
  act(() => root.unmount());
  root = createRoot(host);
  render(row);
};
const click = (element: Element) =>
  act(() => {
    element.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true }));
  });
const body = () => host.querySelector(".cv-user__text")!;
const toggle = () => host.querySelector<HTMLButtonElement>(".cv-user__more");

try {
  test("a 2,000-line prompt opens collapsed on its first lines, faded, with Show more", () => {
    resetTranscriptDisclosure();
    const text = lines(2000);
    render(prompt("user-1", text));
    expect(COLLAPSED_PROMPT_LINES).toBe(10);
    expect(body().classList.contains("is-clamped")).toBe(true);
    expect(body().classList.contains("is-faded")).toBe(true);
    // The whole prompt stays in the bubble: select and Find read all of it; only its height is clamped.
    expect(body().textContent).toBe(text);
    expect(toggle()?.textContent).toBe(MORE);
    expect(toggle()?.getAttribute("aria-expanded")).toBe("false");
    expect(toggle()?.getAttribute("aria-controls")).toBe(body().id);
    // A plain text button: its words name it, no tooltip over them.
    expect(toggle()?.hasAttribute("title")).toBe(false);
    // The hover row is still under the bubble.
    expect(host.querySelector(COPY)).not.toBeNull();
  });

  test("Show more opens it, Show less closes it, and the choice outlives the row's mount", () => {
    resetTranscriptDisclosure();
    const row = prompt("user-2", lines(40));
    render(row);
    click(toggle()!);
    expect(body().classList.contains("is-clamped")).toBe(false);
    expect(body().classList.contains("is-faded")).toBe(false);
    expect(toggle()?.textContent).toBe(LESS);
    expect(toggle()?.getAttribute("aria-expanded")).toBe("true");
    remount(row);
    expect(toggle()?.textContent).toBe(LESS);
    expect(body().classList.contains("is-clamped")).toBe(false);
    click(toggle()!);
    expect(body().classList.contains("is-clamped")).toBe(true);
    remount(row);
    expect(toggle()?.textContent).toBe(MORE);
  });

  test("Copy copies the whole prompt while it is collapsed", async () => {
    resetTranscriptDisclosure();
    const text = lines(2000);
    render(prompt("user-3", text));
    copied.length = 0;
    await act(async () => {
      host.querySelector(COPY)!.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true }));
      await Promise.resolve();
    });
    expect(copied).toEqual([text]);
  });

  test("a short prompt draws as before: no clamp, no fade, no toggle", () => {
    resetTranscriptDisclosure();
    render(prompt("user-4", "Add retry with backoff to the uploader"));
    expect(body().textContent).toBe("Add retry with backoff to the uploader");
    expect(body().classList.contains("is-faded")).toBe(false);
    expect(toggle()).toBeNull();
  });

  // Leo 2026-10-21: prompts drew as empty grey bubbles. A prompt with no text to read draws no
  // bubble; one of images alone is its images (agent-pane-blank-prompt.test.ts covers the ingest).
  test("a prompt of images alone draws its images and no empty bubble", () => {
    resetTranscriptDisclosure();
    render(prompt("user-6", "", { images: [{ id: "img-1", mimeType: "image/png", name: "screen.png" }] }));
    expect(host.querySelector(".cv-user__images")).not.toBeNull();
    expect(host.querySelector(".cv-user__bubble")).toBeNull();
    render(prompt("user-7", " \n "));
    expect(host.querySelector(".cv-user__bubble")).toBeNull();
  });

  test("Find opens a collapsed prompt whose text holds the current match", () => {
    resetTranscriptDisclosure();
    const row = prompt("user-5", lines(300));
    let repainted = 0;
    render(row, { rowId: "user-5", card: false, needle: "line 250", repaint: () => repainted++ });
    expect(body().classList.contains("is-clamped")).toBe(false);
    expect(toggle()?.textContent).toBe(LESS);
    expect(repainted).toBeGreaterThan(0);
  });

  test("a pasted block is a chip, its first words and line count, that opens in place", async () => {
    resetTranscriptDisclosure();
    const typed = "Why does this fail?";
    const paste = lines(2300, "error at frame");
    const text = `${typed}\n${paste}`;
    const start = typed.length + 1;
    const row = prompt("user-6", text, { pasted: [{ start, end: start + paste.length }] });
    // A fresh mount: the last test's Copy still shows its check.
    remount(row);
    const chip = host.querySelector<HTMLButtonElement>(".cv-user__paste")!;
    expect(chip).not.toBeNull();
    // The composer's attachment chip look (#23100), without its remove button.
    expect(chip.classList.contains("acpmux-attachment")).toBe(true);
    expect(chip.querySelector(".cv-user__paste-name")?.textContent).toBe("error at frame 1");
    expect(chip.querySelector(".cv-user__paste-lines")?.textContent).toBe(
      translate("transcript.pastedLines", { n: 2300, count: "2,300" }),
    );
    expect(chip.getAttribute("aria-expanded")).toBe("false");
    expect(host.querySelector(".acpmux-attachment-remove, [aria-label='Remove']")).toBeNull();
    // Closed, the paste's text is not drawn; the typed words are.
    expect(body().textContent).toContain(typed);
    expect(body().textContent).not.toContain("error at frame 2300");
    click(chip);
    expect(host.querySelector(".cv-user__paste")?.getAttribute("aria-expanded")).toBe("true");
    expect(host.querySelector(".cv-user__paste-text")?.textContent).toBe(paste);
    // Copy is the prompt as sent, paste included.
    copied.length = 0;
    await act(async () => {
      host.querySelector(COPY)!.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true }));
      await Promise.resolve();
    });
    expect(copied).toEqual([text]);
  });

  test("Find opens the closed paste chip that holds the match", () => {
    resetTranscriptDisclosure();
    const typed = "See the log";
    const paste = lines(50, "frame");
    const start = typed.length + 1;
    const row = prompt("user-7", `${typed}\n${paste}`, { pasted: [{ start, end: start + paste.length }] });
    render(row, { rowId: "user-7", card: false, needle: "frame 42", repaint: () => {} });
    expect(host.querySelector(".cv-user__paste")?.getAttribute("aria-expanded")).toBe("true");
    expect(host.querySelector(".cv-user__paste-text")?.textContent).toContain("frame 42");
  });

  test("Find's current match lands in the opened paste, never on the chip's name or line count", () => {
    resetTranscriptDisclosure();
    const typed = "Why does this fail?";
    const paste = lines(30, "error at frame");
    const text = `${typed}\n${paste}`;
    const start = typed.length + 1;
    const row = prompt("user-8", text, { pasted: [{ start, end: start + paste.length }] });
    remount(row);
    render(row, { rowId: "user-8", card: false, needle: "error at frame", repaint: () => {} });
    // A stand-in for WebKit's CSS highlight registry.
    const set = new Map<string, unknown>();
    const css = (globalThis as Record<string, unknown>).CSS;
    const highlight = (globalThis as Record<string, unknown>).Highlight;
    Object.assign(globalThis, {
      CSS: { highlights: { set: (name: string, value: unknown) => set.set(name, value), delete: () => {} } },
      Highlight: class {
        constructor(...ranges: Range[]) {
          Object.assign(this, { ranges });
        }
      },
    });
    try {
      const current = paintFindHighlights(host, "error at frame", { rowId: "user-8", card: false, occurrence: 0 });
      expect(current).toBeDefined();
      expect(current!.startContainer.parentElement?.closest(".cv-user__paste-text")).not.toBeNull();
      // Nothing in the chip itself is a match: its name and count are labels, not the prompt's text.
      const all = [...((set.get("acpmux-find") as { ranges: Range[] } | undefined)?.ranges ?? []), current!];
      expect(all.some((range) => range.startContainer.parentElement?.closest(".cv-user__paste"))).toBe(false);
      expect(all.length).toBe(30);
    } finally {
      Object.assign(globalThis, { CSS: css, Highlight: highlight });
    }
  });

  test("Find opens a prompt found long only once laid out, for a match past its fold", () => {
    resetTranscriptDisclosure();
    // A short prompt by its text, with a paste: only its laid-out height says it is long.
    const typed = "See the log";
    const paste = lines(5, "frame");
    const tail = "then the retry gives up";
    const text = `${typed}\n${paste}\n${tail}`;
    const start = typed.length + 1;
    const row = prompt("user-9", text, { pasted: [{ start, end: start + paste.length }] });
    const computed = dom.window.getComputedStyle;
    const scroll = Object.getOwnPropertyDescriptor(dom.window.HTMLElement.prototype, "scrollHeight");
    Object.defineProperty(dom.window.HTMLElement.prototype, "scrollHeight", { configurable: true, get: () => 1000 });
    Object.assign(dom.window, { getComputedStyle: () => ({ lineHeight: "20px" }) });
    // Drawn whole, the prompt is measured by its lines.
    const lineBox = Object.getOwnPropertyDescriptor(dom.window.Range.prototype, "getBoundingClientRect");
    Object.defineProperty(dom.window.Range.prototype, "getBoundingClientRect", {
      configurable: true,
      value: () => ({ height: 1000 }),
    });
    try {
      act(() => root.unmount());
      root = createRoot(host);
      render(row, { rowId: "user-9", card: false, needle: "retry gives up", repaint: () => {} });
      expect(toggle()?.getAttribute("aria-expanded")).toBe("true");
      expect(body().classList.contains("is-clamped")).toBe(false);
    } finally {
      Object.assign(dom.window, { getComputedStyle: computed });
      if (lineBox) Object.defineProperty(dom.window.Range.prototype, "getBoundingClientRect", lineBox);
      else delete (dom.window.Range.prototype as unknown as Record<string, unknown>).getBoundingClientRect;
      if (scroll) Object.defineProperty(dom.window.HTMLElement.prototype, "scrollHeight", scroll);
      else delete (dom.window.HTMLElement.prototype as unknown as Record<string, unknown>).scrollHeight;
    }
  });

  test("a prompt mount does not read animation styles until the person toggles its fold", () => {
    resetTranscriptDisclosure();
    const duration = foldMotion.duration;
    const reducedMotion = foldMotion.reducedMotion;
    const animate = Object.getOwnPropertyDescriptor(dom.window.HTMLElement.prototype, "animate");
    let durationReads = 0;
    Object.defineProperty(dom.window.HTMLElement.prototype, "animate", {
      configurable: true,
      value: () => ({ cancel() {} }),
    });
    foldMotion.reducedMotion = () => false;
    foldMotion.duration = () => {
      durationReads += 1;
      return 0;
    };
    try {
      act(() => root.unmount());
      root = createRoot(host);
      render(prompt("user-fold-style", lines(20)));
      expect(durationReads).toBe(0);
      click(toggle()!);
      expect(body().classList.contains("is-clamped")).toBe(false);
      expect(durationReads).toBe(1);
    } finally {
      foldMotion.duration = duration;
      foldMotion.reducedMotion = reducedMotion;
      if (animate) Object.defineProperty(dom.window.HTMLElement.prototype, "animate", animate);
      else delete (dom.window.HTMLElement.prototype as unknown as Record<string, unknown>).animate;
    }
  });

  test("a short prompt still observes a later font or width change past the fold", () => {
    resetTranscriptDisclosure();
    const computed = dom.window.getComputedStyle;
    const observer = scope.ResizeObserver;
    const scroll = Object.getOwnPropertyDescriptor(dom.window.HTMLElement.prototype, "scrollHeight");
    const lineBox = Object.getOwnPropertyDescriptor(dom.window.Range.prototype, "getBoundingClientRect");
    const observers = new Set<() => void>();
    let drawnHeight = 20;
    Object.defineProperty(dom.window.HTMLElement.prototype, "scrollHeight", {
      configurable: true,
      get: () => drawnHeight,
    });
    Object.assign(dom.window, { getComputedStyle: () => ({ lineHeight: "20px" }) });
    Object.defineProperty(dom.window.Range.prototype, "getBoundingClientRect", {
      configurable: true,
      value: () => ({ height: drawnHeight }),
    });
    scope.ResizeObserver = class {
      constructor(private changed: () => void) {}
      observe() {
        observers.add(this.changed);
      }
      disconnect() {
        observers.delete(this.changed);
      }
    };
    try {
      render(prompt("user-short-geometry", "word ".repeat(12).trim()));
      expect(toggle()).toBeNull();
      expect(observers.size).toBeGreaterThan(0);
      // A later font load or narrower pane wraps the same mounted prompt past ten lines.
      drawnHeight = 240;
      act(() => {
        for (const changed of observers) changed();
      });
      expect(body().classList.contains("is-clamped")).toBe(true);
      expect(toggle()?.getAttribute("aria-expanded")).toBe("false");
    } finally {
      scope.ResizeObserver = observer;
      Object.assign(dom.window, { getComputedStyle: computed });
      if (lineBox) Object.defineProperty(dom.window.Range.prototype, "getBoundingClientRect", lineBox);
      else delete (dom.window.Range.prototype as unknown as Record<string, unknown>).getBoundingClientRect;
      if (scroll) Object.defineProperty(dom.window.HTMLElement.prototype, "scrollHeight", scroll);
      else delete (dom.window.HTMLElement.prototype as unknown as Record<string, unknown>).scrollHeight;
    }
  });

  test("paste ranges are read defensively: sorted, inside the text, never overlapping", () => {
    const text = "abcdefghij";
    expect(pasteRanges(undefined, text)).toEqual([]);
    expect(pasteRanges("nope", text)).toEqual([]);
    expect(
      pasteRanges(
        [
          { start: 6, end: 9 },
          { start: 1, end: 3 },
          { start: 2, end: 5 },
          { start: 8, end: 40 },
          { start: 4, end: 4 },
          { start: "1", end: 2 },
        ],
        text,
      ),
    ).toEqual([
      { start: 1, end: 3 },
      { start: 6, end: 9 },
    ]);
  });
} finally {
  afterAll(() => {
    act(() => root.unmount());
    dom.window.close();
    for (const [key, had, value] of saved) {
      if (had) scope[key] = value;
      else delete scope[key];
    }
  });
}
