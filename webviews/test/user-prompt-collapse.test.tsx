// l10n-allow-file: test fixture prompts, not shipped UI.
// Leo 2026-10-21: a long prompt collapses as Claude's does. A sent prompt longer than twenty lines
// shows its first twenty (Leo 2026-11-07: "show more than we are showing right now"), the last ones fading out, with a Show more / Show less toggle under them; the hover
// row stays, and Copy copies the whole prompt. The choice is kept by the row's id (the transcript
// disclosure store), so a prompt scrolled out and back, or drawn again from history, stays as the
// reader left it. A block the composer marked as pasted (`user_message.pasted`, UTF-16 ranges into
// its text) is a card of its first lines over its size, that opens in place. Find opens a collapsed
// prompt or chip that holds the current match.
//
// The browser test (agent-pane-long-prompt.test.ts) measures the drawn height; this one checks the
// structure, the toggle, Copy and the paste ranges.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { teardownDom } from "./support/domTeardown";

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
  // A browser delivers each new observation once before the frame paints; the prompt measures there
  // (PromptText.tsx). Delivered at once here, inside the same act.
  ResizeObserver: class {
    constructor(private changed: (entries: unknown[]) => void) {}
    observe() {
      this.changed([]);
    }
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

const { act, Profiler } = await import("react");
const { createRoot } = await import("react-dom/client");
const { UserBubble } = await import("../src/agent-session/acpmux/conversation/UserBubble");
const { PromptText } = await import("../src/agent-session/acpmux/conversation/PromptText");
const { foldMotion } = await import("../src/agent-session/acpmux/conversation/fold");
const { FindReveal } = await import("../src/agent-session/acpmux/conversation/chatFind");
const { resetTranscriptDisclosure } =
  await import("../src/agent-session/acpmux/conversation/transcriptDisclosureModel");
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

/// Lays out every box and line of the prompt's text as one `height()` tall (PromptText.tsx
/// laidOutHeight reads them, open or clamped); returns the undo.
function laidOut(height: () => number): () => void {
  const element = Object.getOwnPropertyDescriptor(dom.window.Element.prototype, "getBoundingClientRect");
  const line = Object.getOwnPropertyDescriptor(dom.window.Range.prototype, "getBoundingClientRect");
  const box = () => {
    const tall = height();
    return { top: 0, bottom: tall, height: tall, left: 0, right: 100, width: 100 };
  };
  Object.defineProperty(dom.window.Element.prototype, "getBoundingClientRect", { configurable: true, value: box });
  Object.defineProperty(dom.window.Range.prototype, "getBoundingClientRect", { configurable: true, value: box });
  return () => {
    if (element) Object.defineProperty(dom.window.Element.prototype, "getBoundingClientRect", element);
    if (line) Object.defineProperty(dom.window.Range.prototype, "getBoundingClientRect", line);
    else delete (dom.window.Range.prototype as unknown as Record<string, unknown>).getBoundingClientRect;
  };
}

// Supply layout that JSDOM does not perform, while keeping the real component, effects and
// observer lifecycle. The profiler counts commits, not timings on the test machine.
function measuredPrompt(
  initialHeight: number,
  run: (fixture: {
    render: (text: string) => void;
    resize: (height: number) => void;
    commits: string[];
    measurements: () => number;
  }) => void,
) {
  act(() => root.unmount());
  resetTranscriptDisclosure();
  root = createRoot(host);
  const computed = dom.window.getComputedStyle;
  const observer = scope.ResizeObserver;
  const observers = new Set<() => void>();
  // A browser's observer delivers each new observation once, after the frame's layout and before
  // its paint: the prompt measures there, not in its commit (PromptText.tsx).
  const fresh = new Set<() => void>();
  const deliver = () => {
    const due = [...fresh];
    fresh.clear();
    for (const changed of due) changed();
  };
  const commits: string[] = [];
  let height = initialHeight;
  let measurements = 0;
  const readHeight = () => {
    measurements += 1;
    return height;
  };
  const undoLayout = laidOut(readHeight);
  Object.assign(dom.window, { getComputedStyle: () => ({ lineHeight: "20px" }) });
  scope.ResizeObserver = class {
    constructor(private changed: () => void) {}
    observe() {
      observers.add(this.changed);
      fresh.add(this.changed);
    }
    disconnect() {
      observers.delete(this.changed);
      fresh.delete(this.changed);
    }
  };
  const show = (text: string) => text;
  try {
    run({
      render: (text) => {
        act(() =>
          root.render(
            <Profiler id="prompt" onRender={(_id, phase) => commits.push(phase)}>
              <div className="cv-user__bubble">
                <PromptText rowId="measured-prompt" text={text} show={show} />
              </div>
            </Profiler>,
          ),
        );
        act(deliver);
      },
      resize: (next) => {
        height = next;
        expect(observers.size).toBe(1);
        act(() => {
          observers.values().next().value!();
        });
      },
      commits,
      measurements: () => measurements,
    });
  } finally {
    act(() => root.unmount());
    root = createRoot(host);
    scope.ResizeObserver = observer;
    Object.assign(dom.window, { getComputedStyle: computed });
    undoLayout();
  }
}

try {
  test("measuring a short prompt confirms its first render without a second commit", () => {
    measuredPrompt(20, ({ render, resize, commits, measurements }) => {
      const text = "Keep every visible row rendered";
      render(text);
      expect(measurements()).toBeGreaterThan(0);
      expect(body().textContent).toBe(text);
      expect(toggle()).toBeNull();
      expect(commits).toEqual(["mount"]);
      const before = measurements();
      resize(40);
      expect(measurements()).toBeGreaterThan(before);
      expect(commits).toEqual(["mount"]);
    });
  });

  test("measuring a long prompt confirms its initial clamp without a second commit", () => {
    measuredPrompt(480, ({ render, commits, measurements }) => {
      const text = lines(22);
      render(text);
      expect(measurements()).toBeGreaterThan(0);
      expect(body().textContent).toBe(text);
      expect(body().classList.contains("is-clamped")).toBe(true);
      expect(toggle()?.getAttribute("aria-expanded")).toBe("false");
      expect(commits).toEqual(["mount"]);
    });
  });

  test("a measured prompt folds and unfolds when its width crosses twenty lines", () => {
    measuredPrompt(20, ({ render, resize }) => {
      const text = "word ".repeat(12).trim();
      render(text);
      resize(480);
      expect(body().classList.contains("is-clamped")).toBe(true);
      expect(toggle()?.getAttribute("aria-expanded")).toBe("false");
      resize(40);
      expect(body().classList.contains("is-clamped")).toBe(false);
      expect(toggle()).toBeNull();
      expect(body().textContent).toBe(text);
    });
  });

  test("new content ignores the previous prompt measurement and still follows later resize", () => {
    measuredPrompt(480, ({ render, resize }) => {
      render("A short guess that wraps in a narrow bubble");
      expect(body().classList.contains("is-clamped")).toBe(true);
      // Same mounted component, different text: the old short guess must not override a new
      // long guess, and the new measurement must be able to correct that guess either way.
      resize(40);
      render(lines(22));
      expect(toggle()).toBeNull();
      resize(480);
      expect(body().classList.contains("is-clamped")).toBe(true);
      render("Replacement short text");
      expect(body().classList.contains("is-clamped")).toBe(true);
      resize(40);
      expect(toggle()).toBeNull();
      expect(body().textContent).toBe("Replacement short text");
    });
  });

  test("a 2,000-line prompt opens collapsed on its first lines, faded, with Show more", () => {
    resetTranscriptDisclosure();
    const text = lines(2000);
    render(prompt("user-1", text));
    expect(COLLAPSED_PROMPT_LINES).toBe(20);
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

  // ask-14d16a6247 (Leo, 2026-11-07: "Like just don't separate these out. And, like, I thought we
  // said, you know, remove these inner bubbles, inner, inner cards."): a paste is part of the
  // message's one text body, under the bubble's one fold, which Find opens. Copy is the prompt as sent.
  test("a paste is part of the message's one body under one fold, which Find opens", async () => {
    resetTranscriptDisclosure();
    const typed = "See the log";
    const paste = lines(50, "frame");
    const start = typed.length + 1;
    const text = `${typed}\n${paste}`;
    const row = prompt("user-text-paste", text, { pasted: [{ start, end: start + paste.length }] });
    remount(row);
    expect(host.querySelector(".cv-user__paste, .cv-user__paste-card, .cv-user__pasted")).toBeNull();
    expect(body().querySelectorAll(".cv-user__typed")).toHaveLength(1);
    expect(body().textContent).toBe(text);
    // Fifty lines fold under the prompt's one Show more.
    expect(body().classList.contains("is-clamped")).toBe(true);
    expect(toggle()?.textContent).toBe(MORE);
    expect(host.querySelectorAll("[aria-expanded]")).toHaveLength(1);
    copied.length = 0;
    await act(async () => {
      host.querySelector(COPY)!.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true }));
      await Promise.resolve();
    });
    expect(copied).toEqual([text]);
    render(row, { rowId: "user-text-paste", card: false, needle: "frame 42", repaint: () => {} });
    expect(body().classList.contains("is-clamped")).toBe(false);
  });

  test("Find's matches in a paste land in the message's body text", () => {
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
      expect(current!.startContainer.parentElement?.closest(".cv-user__typed")).not.toBeNull();
      const all = [...((set.get("acpmux-find") as { ranges: Range[] } | undefined)?.ranges ?? []), current!];
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
    Object.assign(dom.window, { getComputedStyle: () => ({ lineHeight: "20px" }) });
    // Laid out, its parts are 1000px tall.
    const undoLayout = laidOut(() => 1000);
    try {
      act(() => root.unmount());
      root = createRoot(host);
      render(row, { rowId: "user-9", card: false, needle: "retry gives up", repaint: () => {} });
      expect(toggle()?.getAttribute("aria-expanded")).toBe("true");
      expect(body().classList.contains("is-clamped")).toBe(false);
    } finally {
      Object.assign(dom.window, { getComputedStyle: computed });
      undoLayout();
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
      render(prompt("user-fold-style", lines(30)));
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
    const observers = new Set<() => void>();
    let drawnHeight = 20;
    const undoLayout = laidOut(() => drawnHeight);
    Object.assign(dom.window, { getComputedStyle: () => ({ lineHeight: "20px" }) });
    scope.ResizeObserver = class {
      constructor(private changed: () => void) {}
      observe() {
        observers.add(this.changed);
        this.changed();
      }
      disconnect() {
        observers.delete(this.changed);
      }
    };
    try {
      render(prompt("user-short-geometry", "word ".repeat(12).trim()));
      expect(toggle()).toBeNull();
      expect(observers.size).toBeGreaterThan(0);
      // A later font load or narrower pane wraps the same mounted prompt past twenty lines.
      drawnHeight = 480;
      act(() => {
        for (const changed of observers) changed();
      });
      expect(body().classList.contains("is-clamped")).toBe(true);
      expect(toggle()?.getAttribute("aria-expanded")).toBe("false");
    } finally {
      scope.ResizeObserver = observer;
      Object.assign(dom.window, { getComputedStyle: computed });
      undoLayout();
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
  afterAll(async () => {
    act(() => root.unmount());
    await teardownDom(saved, { window: dom.window, scope });
  });
}
