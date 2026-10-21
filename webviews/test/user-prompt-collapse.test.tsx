// l10n-allow-file: test fixture prompts, not shipped UI.
// Leo 2026-10-21: a long prompt collapses as Claude's does. A sent prompt longer than ten lines
// shows its first ten, the last ones fading out, with Show more / Show less under them; the hover
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
const { FindReveal } = await import("../src/agent-session/acpmux/conversation/chatFind");
const { resetTranscriptDisclosure } = await import("../src/agent-session/acpmux/conversation/transcriptDisclosure");
const { pasteRanges, COLLAPSED_PROMPT_LINES } = await import("../src/agent-session/acpmux/conversation/promptCollapse");

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
        <UserBubble row={row} text={row.text ?? ""} />
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
    expect(toggle()?.textContent).toBe("Show more");
    expect(toggle()?.getAttribute("aria-expanded")).toBe("false");
    expect(toggle()?.getAttribute("aria-controls")).toBe(body().id);
    // A plain text button: its words name it, no tooltip over them.
    expect(toggle()?.hasAttribute("title")).toBe(false);
    // The hover row is still under the bubble.
    expect(host.querySelector(".cv-user__actions button[aria-label='Copy']")).not.toBeNull();
  });

  test("Show more opens it, Show less closes it, and the choice outlives the row's mount", () => {
    resetTranscriptDisclosure();
    const row = prompt("user-2", lines(40));
    render(row);
    click(toggle()!);
    expect(body().classList.contains("is-clamped")).toBe(false);
    expect(body().classList.contains("is-faded")).toBe(false);
    expect(toggle()?.textContent).toBe("Show less");
    expect(toggle()?.getAttribute("aria-expanded")).toBe("true");
    remount(row);
    expect(toggle()?.textContent).toBe("Show less");
    expect(body().classList.contains("is-clamped")).toBe(false);
    click(toggle()!);
    expect(body().classList.contains("is-clamped")).toBe(true);
    remount(row);
    expect(toggle()?.textContent).toBe("Show more");
  });

  test("Copy copies the whole prompt while it is collapsed", async () => {
    resetTranscriptDisclosure();
    const text = lines(2000);
    render(prompt("user-3", text));
    copied.length = 0;
    await act(async () => {
      host
        .querySelector(".cv-user__actions button[aria-label='Copy']")!
        .dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true }));
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

  test("Find opens a collapsed prompt whose text holds the current match", () => {
    resetTranscriptDisclosure();
    const row = prompt("user-5", lines(300));
    let repainted = 0;
    render(row, { rowId: "user-5", card: false, needle: "line 250", repaint: () => repainted++ });
    expect(body().classList.contains("is-clamped")).toBe(false);
    expect(toggle()?.textContent).toBe("Show less");
    expect(repainted).toBeGreaterThan(0);
  });

  test("a pasted block is a chip, its first words and line count, that opens in place", async () => {
    resetTranscriptDisclosure();
    const typed = "Why does this fail?";
    const paste = lines(2300, "error at frame");
    const text = `${typed}\n${paste}`;
    const start = typed.length + 1;
    const row = prompt("user-6", text, { pasted: [{ start, end: start + paste.length }] });
    render(row);
    const chip = host.querySelector<HTMLButtonElement>(".cv-user__paste")!;
    expect(chip).not.toBeNull();
    // The composer's attachment chip look (#23100), without its remove button.
    expect(chip.classList.contains("acpmux-attachment")).toBe(true);
    expect(chip.querySelector(".cv-user__paste-name")?.textContent).toBe("error at frame 1");
    expect(chip.querySelector(".cv-user__paste-lines")?.textContent).toBe("2,300 lines");
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
      host
        .querySelector(".cv-user__actions button[aria-label='Copy']")!
        .dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true }));
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
