// l10n-allow-file: test fixture prompts, not shipped UI.
// Leo 2026-10-21: a long prompt collapses as Claude's does. A sent prompt longer than ten lines
// shows its first ten, the last ones fading out, with a Show more / Show less toggle under them; the hover
// row stays, and Copy copies the whole prompt. The choice is kept by the row's id (the transcript
// disclosure store), so a prompt scrolled out and back, or drawn again from history, stays as the
// reader left it. A block the composer marked as pasted (`user_message.pasted`, UTF-16 ranges into
// its text) is the message's own text in the bubble, under the same Show more: no "Pasted text"
// card of its own (Leo, 2026-11-08). Find opens a collapsed prompt that holds the current match.
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

const { act, Profiler } = await import("react");
const { createRoot } = await import("react-dom/client");
const { UserBubble } = await import("../src/agent-session/acpmux/conversation/UserBubble");
const { PromptText } = await import("../src/agent-session/acpmux/conversation/PromptText");
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
  const scroll = Object.getOwnPropertyDescriptor(dom.window.HTMLElement.prototype, "scrollHeight");
  const lineBox = Object.getOwnPropertyDescriptor(dom.window.Range.prototype, "getBoundingClientRect");
  const observers = new Set<() => void>();
  const commits: string[] = [];
  let height = initialHeight;
  let measurements = 0;
  const readHeight = () => {
    measurements += 1;
    return height;
  };
  Object.defineProperty(dom.window.HTMLElement.prototype, "scrollHeight", { configurable: true, get: readHeight });
  Object.assign(dom.window, { getComputedStyle: () => ({ lineHeight: "20px" }) });
  Object.defineProperty(dom.window.Range.prototype, "getBoundingClientRect", {
    configurable: true,
    value: () => ({ height: readHeight() }),
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
  const show = (text: string) => text;
  try {
    run({
      render: (text) =>
        act(() =>
          root.render(
            <Profiler id="prompt" onRender={(_id, phase) => commits.push(phase)}>
              <div className="cv-user__bubble">
                <PromptText rowId="measured-prompt" text={text} show={show} />
              </div>
            </Profiler>,
          ),
        ),
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
    if (lineBox) Object.defineProperty(dom.window.Range.prototype, "getBoundingClientRect", lineBox);
    else delete (dom.window.Range.prototype as unknown as Record<string, unknown>).getBoundingClientRect;
    if (scroll) Object.defineProperty(dom.window.HTMLElement.prototype, "scrollHeight", scroll);
    else delete (dom.window.HTMLElement.prototype as unknown as Record<string, unknown>).scrollHeight;
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
    measuredPrompt(240, ({ render, commits, measurements }) => {
      const text = lines(12);
      render(text);
      expect(measurements()).toBeGreaterThan(0);
      expect(body().textContent).toBe(text);
      expect(body().classList.contains("is-clamped")).toBe(true);
      expect(toggle()?.getAttribute("aria-expanded")).toBe("false");
      expect(commits).toEqual(["mount"]);
    });
  });

  test("a measured prompt folds and unfolds when its width crosses ten lines", () => {
    measuredPrompt(20, ({ render, resize }) => {
      const text = "word ".repeat(12).trim();
      render(text);
      resize(240);
      expect(body().classList.contains("is-clamped")).toBe(true);
      expect(toggle()?.getAttribute("aria-expanded")).toBe("false");
      resize(40);
      expect(body().classList.contains("is-clamped")).toBe(false);
      expect(toggle()).toBeNull();
      expect(body().textContent).toBe(text);
    });
  });

  test("new content ignores the previous prompt measurement and still follows later resize", () => {
    measuredPrompt(240, ({ render, resize }) => {
      render("A short guess that wraps in a narrow bubble");
      expect(body().classList.contains("is-clamped")).toBe(true);
      // Same mounted component, different text: the old short guess must not override a new
      // long guess, and the new measurement must be able to correct that guess either way.
      resize(40);
      render(lines(12));
      expect(toggle()).toBeNull();
      resize(240);
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

  const CARD = ".cv-user__paste, .cv-user__paste-card, .cv-user__paste-block";

  // Leo, 2026-11-08: "It also seems like this pasted text bit wasn't fixed yet". A paste in a sent
  // message is its own text, among the typed words, never a "Pasted text" card.
  test("a sent message with pasted text renders it as plain bubble text, with no Pasted text block", () => {
    resetTranscriptDisclosure();
    const typed = "Can you tighten this paragraph?";
    const paste =
      "The uploader retries a failed part three times with a fixed delay, which floods the server " +
      "when it is already struggling; it should back off exponentially, add jitter and give up " +
      "after a bounded total wait so the person knows why.";
    expect(paste.length).toBe(230);
    const text = `${typed}\n${paste}`;
    const start = typed.length + 1;
    remount(prompt("user-plain-paste", text, { pasted: [{ start, end: start + paste.length }] }));
    // The paste's text is the bubble's own text, after the typed words.
    expect(body().textContent).toContain(typed);
    expect(body().textContent).toContain(paste);
    expect(body().querySelector(".cv-user__pasted")?.textContent).toBe(paste);
    // No card, no label, no Show more for a short message.
    expect(host.querySelector(CARD)).toBeNull();
    expect(host.textContent).not.toContain(translate("composer.pastedText"));
    expect(toggle()).toBeNull();
    expect(body().classList.contains("is-clamped")).toBe(false);
  });

  test("a sent message with a 40-line paste folds under the message's own Show more", () => {
    resetTranscriptDisclosure();
    const typed = "See the log";
    const paste = lines(40, "frame");
    const text = `${typed}\n${paste}`;
    const start = typed.length + 1;
    remount(prompt("user-40-paste", text, { pasted: [{ start, end: start + paste.length }] }));
    expect(host.querySelector(CARD)).toBeNull();
    expect(body().querySelector(".cv-user__pasted")?.textContent).toBe(paste);
    expect(body().classList.contains("is-clamped")).toBe(true);
    expect(toggle()?.textContent).toBe(MORE);
    expect(toggle()?.getAttribute("aria-expanded")).toBe("false");
    click(toggle()!);
    expect(body().classList.contains("is-clamped")).toBe(false);
    expect(toggle()?.textContent).toBe(LESS);
  });

  test("a 2,300-line paste is the message's own text, collapsed under Show more, and Copy copies it all", async () => {
    resetTranscriptDisclosure();
    const typed = "Why does this fail?";
    const paste = lines(2300, "error at frame");
    const text = `${typed}\n${paste}`;
    const start = typed.length + 1;
    const row = prompt("user-6", text, { pasted: [{ start, end: start + paste.length }] });
    // A fresh mount: the last test's Copy still shows its check.
    remount(row);
    // No card of its own: the typed words, then the paste, in the bubble's one text.
    expect(host.querySelector(CARD)).toBeNull();
    expect(host.querySelector(".acpmux-attachment-remove, [aria-label='Remove']")).toBeNull();
    expect(body().textContent).toContain(typed);
    expect(body().querySelector(".cv-user__pasted")?.textContent).toBe(paste);
    expect(body().textContent!.indexOf(typed)).toBeLessThan(body().textContent!.indexOf("error at frame 1"));
    // Long, it opens collapsed on its first lines with the message's own Show more.
    expect(body().classList.contains("is-clamped")).toBe(true);
    expect(toggle()?.textContent).toBe(MORE);
    click(toggle()!);
    expect(body().classList.contains("is-clamped")).toBe(false);
    expect(toggle()?.textContent).toBe(LESS);
    // Copy is the prompt as sent, paste included.
    copied.length = 0;
    await act(async () => {
      host.querySelector(COPY)!.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true }));
      await Promise.resolve();
    });
    expect(copied).toEqual([text]);
  });

  // Leo, 2026-11-05, on the sent bubble's chip: "I think this is almost kind of interesting, but
  // it's, like, really awkward". Since 2026-11-08 a one-paragraph paste is simply the message's
  // text: no size label, no preview box, wrapped at the bubble's width under its Show more.
  test("a one-paragraph paste is the message's text, whole for Find, folded by the message's Show more", () => {
    resetTranscriptDisclosure();
    const typed = "Can you tighten this up?";
    const paste = Array.from({ length: 900 }, (_, index) => `word${index}`).join(" ");
    const text = `${typed}\n${paste}`;
    const start = typed.length + 1;
    remount(prompt("user-9", text, { pasted: [{ start, end: start + paste.length }] }));
    expect(host.querySelector(CARD)).toBeNull();
    expect(host.querySelector(".cv-user__bubble .acpmux-attachment")).toBeNull();
    expect(host.textContent).not.toContain(translate("composer.pastedText"));
    // The whole paste is in the bubble, never a preview, and Find reads it.
    const pasted = body().querySelector<HTMLElement>(".cv-user__pasted")!;
    expect(pasted.textContent).toBe(paste);
    expect(pasted.closest("[data-find-skip]")).toBeNull();
    // Over a thousand characters, it guesses long: collapsed under Show more, which opens it.
    expect(body().classList.contains("is-clamped")).toBe(true);
    expect(toggle()?.getAttribute("aria-expanded")).toBe("false");
    click(toggle()!);
    expect(body().classList.contains("is-clamped")).toBe(false);
    expect(toggle()?.getAttribute("aria-expanded")).toBe("true");
    click(toggle()!);
    expect(body().classList.contains("is-clamped")).toBe(true);
  });

  // A paste is measured as the rest of the message's text (PromptText.tsx `drawnBox`): drawn short
  // it keeps the prompt whole, drawn past ten lines it folds the prompt.
  test("a paste is measured as the message's own text: drawn short it stays whole, drawn tall it folds", () => {
    const computed = dom.window.getComputedStyle;
    const scroll = Object.getOwnPropertyDescriptor(dom.window.HTMLElement.prototype, "scrollHeight");
    const lineBox = Object.getOwnPropertyDescriptor(dom.window.Range.prototype, "getBoundingClientRect");
    let height = 40;
    Object.assign(dom.window, { getComputedStyle: () => ({ lineHeight: "20px" }) });
    Object.defineProperty(dom.window.HTMLElement.prototype, "scrollHeight", { configurable: true, get: () => height });
    Object.defineProperty(dom.window.Range.prototype, "getBoundingClientRect", {
      configurable: true,
      value: () => ({ top: 0, bottom: height, height }),
    });
    const typed = "Can you tighten this up?";
    const paste = "A short pasted paragraph that wraps onto a second line in a narrow bubble.";
    const text = `${typed}\n${paste}`;
    const start = typed.length + 1;
    const draw = (rowId: string) => {
      act(() => root.unmount());
      resetTranscriptDisclosure();
      root = createRoot(host);
      act(() =>
        root.render(
          <div className="cv-user__bubble">
            <PromptText rowId={rowId} text={text} pasted={[{ start, end: text.length }]} show={(value) => value} />
          </div>,
        ),
      );
    };
    try {
      draw("measured-short-paste");
      expect(host.querySelector(CARD)).toBeNull();
      expect(body().classList.contains("is-clamped")).toBe(false);
      expect(toggle()).toBeNull();
      height = 600;
      draw("measured-tall-paste");
      expect(body().classList.contains("is-clamped")).toBe(true);
      expect(toggle()?.getAttribute("aria-expanded")).toBe("false");
    } finally {
      act(() => root.unmount());
      root = createRoot(host);
      Object.assign(dom.window, { getComputedStyle: computed });
      if (lineBox) Object.defineProperty(dom.window.Range.prototype, "getBoundingClientRect", lineBox);
      else delete (dom.window.Range.prototype as unknown as Record<string, unknown>).getBoundingClientRect;
      if (scroll) Object.defineProperty(dom.window.HTMLElement.prototype, "scrollHeight", scroll);
      else delete (dom.window.HTMLElement.prototype as unknown as Record<string, unknown>).scrollHeight;
    }
  });

  test("Find opens the collapsed prompt whose paste holds the match", () => {
    resetTranscriptDisclosure();
    const typed = "See the log";
    const paste = lines(50, "frame");
    const start = typed.length + 1;
    const row = prompt("user-7", `${typed}\n${paste}`, { pasted: [{ start, end: start + paste.length }] });
    act(() => root.unmount());
    root = createRoot(host);
    render(row, { rowId: "user-7", card: false, needle: "frame 42", repaint: () => {} });
    expect(host.querySelector(CARD)).toBeNull();
    expect(body().classList.contains("is-clamped")).toBe(false);
    expect(toggle()?.getAttribute("aria-expanded")).toBe("true");
    expect(body().querySelector(".cv-user__pasted")?.textContent).toContain("frame 42");
  });

  test("Find's matches land in the paste's own text, each line once", () => {
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
      expect(current!.startContainer.parentElement?.closest(".cv-user__pasted")).not.toBeNull();
      // No card or label exists to match: every match is a line of the paste, drawn once.
      expect(host.querySelector(CARD)).toBeNull();
      const all = [...((set.get("acpmux-find") as { ranges: Range[] } | undefined)?.ranges ?? []), current!];
      expect(all.every((range) => range.startContainer.parentElement?.closest(".cv-user__pasted"))).toBe(true);
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
    // Drawn whole, the prompt is measured by its text's lines, the paste's included.
    const lineBox = Object.getOwnPropertyDescriptor(dom.window.Range.prototype, "getBoundingClientRect");
    Object.defineProperty(dom.window.Range.prototype, "getBoundingClientRect", {
      configurable: true,
      value: () => ({ top: 0, bottom: 1000, height: 1000 }),
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
