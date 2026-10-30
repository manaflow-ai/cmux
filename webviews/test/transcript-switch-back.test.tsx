// Leo 2026-10-20: switching tabs or workspaces and coming back to a chat replayed its entrances. A
// tab's agent page stays alive and hidden while another shows, and its reply keeps streaming: each
// row and reply block that arrived got its entrance class while hidden, WebKit suspended the
// animation, and it played when the user came back. Switching away and back must start 0
// entrances (shared-projections.md); a row that arrives while the chat shows still enters.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";
import { pageSwitch } from "./support/pageSwitch";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  customElements: dom.window.customElements,
  Node: dom.window.Node,
  MutationObserver: dom.window.MutationObserver,
  IntersectionObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
// Pierre's registered elements read their own DOM constructors at import time.
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);
Object.defineProperty(dom.window.HTMLElement.prototype, "clientHeight", { configurable: true, get: () => 600 });
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => 760 });

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");
const { Markdown } = await import("../src/agent-session/acpmux/conversation/Markdown");
const { RevealedMarkdown, revealFrames } = await import("../src/agent-session/acpmux/conversation/RevealedMarkdown");
const page = pageSwitch(dom.window);

afterAll(() => {
  page.dispose();
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const row = (id: string, kind: string, text?: string): AcpmuxRow => ({ id, kind, text, version: 1, at: 1 });
const turns = Array.from({ length: 3 }, (_, index) => [
  row(`t${index}-user`, "user", `Question ${index}`),
  row(`t${index}-answer`, "assistant", `Answer ${index}.`),
  { ...row(`t${index}-end`, "turnSummary"), status: "completed", durationMs: 1_000 },
]).flat();

function transcript() {
  const root = createRoot(dom.window.document.getElementById("root")!);
  const render = (rows: AcpmuxRow[]) =>
    root.render(
      <VirtualTranscript rows={turnView(rows, new Set())} onToggleActivity={() => {}} expanded={new Set()} />,
    );
  return { root, render };
}

test("back on a chat, rows that streamed in while it was hidden start no entrance", async () => {
  const { root, render } = transcript();
  try {
    await act(async () => render(turns));
    const seen = await page.switchAwayAndBack({
      // The agent kept working in the hidden tab: its next step arrived.
      away: () => render([...turns, row("t3-user", "user", "Question 3"), row("t3-step", "assistant", "Looking.")]),
      // The reply's next row lands as the chat shows again.
      back: () =>
        render([
          ...turns,
          row("t3-user", "user", "Question 3"),
          row("t3-step", "assistant", "Looking."),
          row("t3-answer", "assistant", "Found it."),
        ]),
    });
    expect(seen).toEqual({ fetches: [], entrances: [] });
  } finally {
    await act(async () => root.unmount());
  }
});

test("a row that arrives while the chat shows still enters", async () => {
  const { root, render } = transcript();
  try {
    await act(async () => render(turns));
    await page.switchAwayAndBack();
    page.reset();
    await act(async () => render([...turns, row("t3-user", "user", "Question 3")]));
    await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
    expect(page.entrances().length).toBeGreaterThan(0);
  } finally {
    await act(async () => root.unmount());
  }
});

test("back on a chat, reply blocks that streamed in while it was hidden start no entrance", async () => {
  const root = createRoot(dom.window.document.getElementById("root")!);
  const render = (text: string) => root.render(<Markdown streaming>{text}</Markdown>);
  try {
    await act(async () => render("First paragraph."));
    const seen = await page.switchAwayAndBack({
      away: () => render("First paragraph.\n\nSecond paragraph, written while hidden."),
      back: () => render("First paragraph.\n\nSecond paragraph, written while hidden.\n\nThird, as it shows."),
    });
    expect(seen).toEqual({ fetches: [], entrances: [] });
    // Streaming on with the chat shown: the next block enters.
    page.reset();
    await act(async () =>
      render(
        "First paragraph.\n\nSecond paragraph, written while hidden.\n\nThird, as it shows.\n\nFourth, while shown.",
      ),
    );
    await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
    expect(page.entrances().length).toBeGreaterThan(0);
  } finally {
    await act(async () => root.unmount());
  }
});

// In the app a streaming reply reveals its text over display frames (RevealedMarkdown), and WebKit
// runs none while the page is hidden: the text that streamed while away waits, then reveals as the
// chat shows again. It must draw at once, with no block entrance and no character fade.
test("back on a chat, a revealed reply's backlog draws at once with no entrance", async () => {
  const request = revealFrames.request;
  const cancel = revealFrames.cancel;
  let queue = new Map<number, (now: number) => void>();
  let nextHandle = 0;
  let clock = 1_000;
  revealFrames.request = (run) => {
    queue.set((nextHandle += 1), run);
    return nextHandle;
  };
  revealFrames.cancel = (handle) => void queue.delete(handle);
  const visible = () => dom.window.document.visibilityState !== "hidden";
  // One display frame: none while hidden; the reveal's ticks, then the page's own frames.
  const frame = async () => {
    if (!visible()) return;
    clock += 16;
    const run = queue;
    queue = new Map();
    await act(async () => {
      for (const tick of run.values()) tick(clock);
      await new Promise((resolve) => dom.window.requestAnimationFrame(resolve));
    });
  };
  const root = createRoot(dom.window.document.getElementById("root")!);
  const render = (text: string) => root.render(<RevealedMarkdown text={text} streaming />);
  try {
    let text = "First paragraph.";
    await act(async () => render(text));
    for (let step = 0; step < 4; step += 1) {
      text += " more words";
      await act(async () => render(text));
      await frame();
    }
    await page.setVisibility("hidden");
    page.reset();
    for (let step = 0; step < 5; step += 1) {
      text += `\n\nParagraph ${step}, streamed while the chat was hidden, with enough text to reveal.`;
      await act(async () => render(text));
    }
    await page.setVisibility("visible");
    for (let step = 0; step < 30; step += 1) await frame();
    expect(dom.window.document.body.textContent).toContain("Paragraph 4");
    expect(page.entrances()).toEqual([]);
  } finally {
    revealFrames.request = request;
    revealFrames.cancel = cancel;
    await act(async () => root.unmount());
  }
});

// A code fence that closed while the chat was hidden hands its plain card over to the highlighted
// one without the cross-fade: nobody watched it close.
test("back on a chat, a code block that closed while it was hidden does not cross-fade", async () => {
  const root = createRoot(dom.window.document.getElementById("root")!);
  const render = (text: string) => root.render(<Markdown streaming>{text}</Markdown>);
  try {
    await act(async () => render("Here:\n\n```js\nconst a = 1;\n"));
    const seen = await page.switchAwayAndBack({
      away: () => render("Here:\n\n```js\nconst a = 1;\n```\n\nDone."),
    });
    // The handoff waits up to a second for the highlighted lines, then hands over.
    const handoff = dom.window.document.querySelector(".cv-code-handoff")!;
    const deadline = performance.now() + 3_000;
    while (handoff.classList.contains("is-plain") && performance.now() < deadline)
      await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
    expect(handoff.classList.contains("is-plain")).toBe(false);
    expect(seen.entrances).toEqual([]);
    expect(page.entrances()).toEqual([]);
    expect(dom.window.document.querySelector(".cv-code-handoff.is-fading")).toBeNull();
  } finally {
    await act(async () => root.unmount());
  }
});

// Leo 2026-10-20 ("no layout shifts" on a switch back): the backlog committed after the first
// frame back had painted (a state update from a frame callback renders in a later task), so that
// frame showed the reply as it was when the user left and the next one grew it and moved the
// transcript. The backlog is in the document when the first frame back's tick returns.
test("back on a chat, a revealed reply's backlog is in the first frame back", async () => {
  const request = revealFrames.request;
  const cancel = revealFrames.cancel;
  let queue = new Map<number, (now: number) => void>();
  let nextHandle = 0;
  revealFrames.request = (run) => {
    queue.set((nextHandle += 1), run);
    return nextHandle;
  };
  revealFrames.cancel = (handle) => void queue.delete(handle);
  const root = createRoot(dom.window.document.getElementById("root")!);
  const render = (text: string) => root.render(<RevealedMarkdown text={text} streaming />);
  try {
    let text = "First paragraph.";
    await act(async () => render(text));
    await page.setVisibility("hidden");
    text += "\n\nWritten while the chat was hidden.";
    await act(async () => render(text));
    await page.setVisibility("visible");
    // The first frame back: its ticks run, then it paints, with no task in between (no act()).
    const run = queue;
    queue = new Map();
    scope.IS_REACT_ACT_ENVIRONMENT = false;
    try {
      for (const tick of run.values()) tick(2_000);
      expect(dom.window.document.body.textContent).toContain("Written while the chat was hidden.");
    } finally {
      scope.IS_REACT_ACT_ENVIRONMENT = true;
    }
    await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  } finally {
    revealFrames.request = request;
    revealFrames.cancel = cancel;
    await act(async () => root.unmount());
  }
});
