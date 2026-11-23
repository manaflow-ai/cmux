// l10n-allow-file: test fixture replies, not shipped UI.
// A streaming reply reads like Claude desktop's and Codex's (Leo 2026-10-19: "remove that block
// ascii blinking cursor thing"; whole words from #22339): nothing trails the newest word (no block
// cursor), and the text grows a whole word at a time, each word fading in, never a letter at a time
// or with a partial word at its end. Once the stream ends, all of it shows.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { act, StrictMode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { RevealedMarkdown } from "./RevealedMarkdown";
import { revealFrames, TurnEndCut } from "./revealedMarkdownModel";
import { wordEdge } from "../streamReveal";
import { acpmuxPerf } from "../perf";
import { settleReact } from "../../../../test/support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
let container: HTMLElement;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const KEYS = ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"];
const savedFrames = { ...revealFrames };
let queued: ((now: number) => void)[] = [];
/// The reveal's clock: the time of the frame running, or of the last one.
let clock = 0;

beforeEach(() => {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
  });
  for (const key of KEYS) saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  container = dom.window.document.getElementById("root")!;
  queued = [];
  revealFrames.request = (callback) => queued.push(callback);
  revealFrames.cancel = () => {};
  clock = 0;
  revealFrames.now = () => clock;
});

afterEach(async () => {
  act(() => root?.unmount());
  root = undefined;
  Object.assign(revealFrames, savedFrames);
  // fixed-wait: teardown only; React's scheduled work runs before its window closes
  await new Promise((resolve) => setTimeout(resolve, 20));
  await settleReact();
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  dom?.window.close();
  dom = undefined;
});

/// Runs display frames 16 ms apart from `from`, returning the reply's text after each.
function frames(from: number, count: number): string[] {
  const seen: string[] = [];
  for (let index = 0; index < count; index++) {
    const pending = queued;
    queued = [];
    act(() => {
      clock = from + index * 16;
      for (const callback of pending) callback(from + index * 16);
    });
    seen.push(container.querySelector(".cv-md")?.textContent ?? "");
  }
  return seen;
}

const render = (text: string, streaming: boolean, artifactIdentity?: string, messageAt?: number) =>
  act(() => {
    root!.render(
      <RevealedMarkdown text={text} streaming={streaming} artifactIdentity={artifactIdentity} messageAt={messageAt} />,
    );
  });

test("a completed reply replaced by its full historical text does not re-reveal", () => {
  root = createRoot(container);
  render("Already visible suffix.", false);
  render("Earlier paragraph.\n\nAlready visible suffix.", false);

  expect(container.querySelector(".cv-md")?.textContent).toBe("Earlier paragraph.Already visible suffix.");
  expect(container.querySelectorAll(".cv-fresh")).toHaveLength(0);
});

test("a recreated reply with a reused row id does not keep the old body", () => {
  root = createRoot(container);
  render("The old session had a longer answer.", false, "assistant-1", 1001);
  render("The new session answer.", false, "assistant-1", 2001);

  expect(container.querySelector(".cv-md")?.textContent).toBe("The new session answer.");
  expect(container.querySelectorAll(".cv-fresh")).toHaveLength(0);
});

for (const strict of [false, true]) {
  test(`a recreated reply cancels a queued frame and keeps streaming (${strict ? "StrictMode" : "ordinary"})`, () => {
    const { pending, frame } = cancellableFrames();
    root = createRoot(container);
    const draw = (text: string, identity: string) =>
      act(() => {
        const reply = <RevealedMarkdown text={text} streaming artifactIdentity={identity} />;
        root!.render(strict ? <StrictMode>{reply}</StrictMode> : reply);
      });
    const visible = () => container.querySelector(".cv-md")?.textContent ?? "";
    draw("", "assistant-1:old");
    draw("The old session is still streaming and has many words waiting for their first frame.", "assistant-1:old");
    // Its whole words show in the commit that brings them; the last word waits to be whole.
    expect(visible()).toBe("The old session is still streaming and has many words waiting for their first");
    expect(pending.size).toBe(1);
    const oldHandle = [...pending.keys()][0]!;

    const replacement = "The new session answer is already visible.";
    draw(replacement, "assistant-1:new");
    expect(pending.has(oldHandle)).toBe(false);
    expect(visible()).toBe(replacement);
    expect(container.querySelectorAll(".cv-fresh")).toHaveLength(0);
    expect(frame(0)).toBe(replacement);
    expect(frame(16)).toBe(replacement);
    expect(pending.size).toBe(0);

    const appended = `${replacement} New words arrive with the chunk that brings them, each fading in.`;
    draw(appended, "assistant-1:new");
    // All of it but the last word, which may still grow, in the same commit; the new words fade in.
    expect(visible()).toBe(appended.slice(0, appended.lastIndexOf(" ")));
    expect(pending.size).toBe(1);
    expect(container.querySelectorAll(".cv-fresh").length).toBeGreaterThan(0);
    expect([frame(32), frame(48), frame(64)].every((text) => text === visible())).toBe(true);
    for (let index = 0; index < 120; index++) frame(80 + index * 16);

    expect(visible()).toBe(appended);
    expect(container.querySelectorAll(".cv-fresh")).toHaveLength(0);
    expect(pending.size).toBe(0);
  });
}

test("a truncated reconnect snapshot never hides already visible assistant text", () => {
  root = createRoot(container);
  render("", true);
  const reply = "The checks on the merged head are green and the notes are ready to send.";
  render(reply, true);
  const before = frames(0, 18).at(-1)!;
  expect(before.length).toBeGreaterThan(0);

  render(reply.slice(0, 12), true);
  expect(container.querySelector(".cv-md")?.textContent?.length ?? 0).toBeGreaterThanOrEqual(before.length);

  render(reply, true);
  frames(18 * 16, 4);
  expect(container.querySelector(".cv-md")?.textContent?.length ?? 0).toBeGreaterThanOrEqual(before.length);
});

test("a streaming reply grows by whole words with nothing after the last one", () => {
  root = createRoot(container);
  render("", true);
  const reply = "The checks on the merged head are green and the release notes are ready to send";
  // Deltas cut words in half, as Claude's do.
  const deltas = ["The che", "cks on the mer", "ged head are gr", "een and the release no", "tes are ready to se"];
  let text = "";
  const seen: string[] = [];
  let at = 0;
  for (const delta of deltas) {
    text += delta;
    render(text, true);
    seen.push(...frames(at, 12));
    at += 12 * 16;
  }
  // Frames until just before the last delta is StreamReveal.stallMs old: until then "se" (of
  // "send") has arrived but is not a whole word yet (after it, the last word shows; see below).
  seen.push(...frames(at, 24));
  at += 24 * 16;
  expect(container.querySelector(".cv-caret")).toBeNull();
  const words = new Set(reply.split(" "));
  for (const shown of seen) {
    if (!shown) continue;
    // Every word on screen is a whole word of the reply; the one still arriving never shows.
    for (const word of shown.split(" ")) expect(words.has(word)).toBe(true);
    expect(shown.endsWith(" ")).toBe(false);
  }
  // The stream ends: the rest shows.
  render(`${text}nd`, false);
  frames(at, 30);
  expect(container.querySelector(".cv-md")?.textContent).toBe(reply);
  expect(container.querySelector(".cv-caret")).toBeNull();
});

test("the newest words fade in, each word whole", () => {
  root = createRoot(container);
  render("", true);
  render("Hello there wor", true);
  // Within StreamReveal.stallMs of the text arriving, "wor" may still grow.
  const shown = frames(0, 30);
  expect(shown.at(-1)).toBe("Hello there");
  render("Hello there world, again", true);
  frames(30 * 16, 1);
  const fresh = [...container.querySelectorAll(".cv-fresh")].map((span) => span.textContent ?? "");
  // Only whole words fade in: " world," arrived whole; "again" may still grow.
  expect(fresh.length).toBeGreaterThan(0);
  expect(
    fresh
      .join("")
      .trim()
      .split(/\s+/)
      .every((word) => ["world,", "Hello", "there"].includes(word)),
  ).toBe(true);
  expect(container.querySelector(".cv-md")?.textContent?.startsWith("Hello there")).toBe(true);
});

test("words after a code span, a parenthesis or a line break still fade in", () => {
  // Leo, 2026-11-03: "hey even u have that text fading in! i want that..." Any Markdown character in
  // the newest text used to skip its fade.
  for (const [before, after, fades] of [
    ["Run `bun test` and", "Run `bun test` and then check the output", "and then check the output"],
    ["It works (mostly", "It works (mostly and quickly now", "mostly and quickly now"],
    ["First line.\nSecond", "First line.\nSecond line goes here", "Second line goes here"],
  ] as const) {
    root = createRoot(container);
    render("", true);
    render(before, true);
    frames(0, 30);
    render(after, true);
    frames(30 * 16, 1);
    const fresh = [...container.querySelectorAll(".cv-fresh")].map((span) => span.textContent ?? "").join("");
    expect(fresh.length).toBeGreaterThan(0);
    // The word held back while the first text waited (StreamReveal.stallMs) fades in first.
    expect(fades.startsWith(fresh.trim())).toBe(true);
    act(() => root?.unmount());
  }
});

test("text inside an unclosed emphasis draws without a fade (the open run is closed for now, safeTail.ts)", () => {
  root = createRoot(container);
  render("", true);
  render("This is **very", true);
  frames(0, 30);
  render("This is **very important stuff here", true);
  frames(30 * 16, 8);
  expect(container.querySelectorAll(".cv-fresh").length).toBe(0);
});

test("fresh text expires with the host fade-in token", () => {
  dom!.window.document.documentElement.style.setProperty("--agent-motion-in", "1000ms");
  root = createRoot(container);
  render("", true);
  render("Hello there wor", true);
  frames(0, 30);
  render("Hello there world, again", true);
  frames(480, 8);
  expect(container.querySelectorAll(".cv-fresh").length).toBeGreaterThan(0);
  frames(800, 1);
  expect(container.querySelectorAll(".cv-fresh").length).toBeGreaterThan(0);
});

const LONG_REPLY = "The checks on the merged head are green and the notes are ready. ".repeat(30);

// Text shows in the commit that brings it, which acpmux's snapshots make once per display frame
// (cmuxterm-hq docs/design/agent-transcript-clean-slate.md, step 3). No pacer lets it through over
// the frames after: they change nothing on screen, so the reply's height changes only when text
// arrives, and its newest words only fade in.
test("a chunk's text shows in the commit that brings it, and the frames after it change nothing", () => {
  root = createRoot(container);
  render("", true);
  render(LONG_REPLY, true);
  const drawn = container.querySelector(".cv-md")?.textContent ?? "";
  expect(drawn).toBe(LONG_REPLY.trim());
  expect(container.querySelectorAll(".cv-fresh").length).toBeGreaterThan(0);
  for (const shown of frames(0, 14)) expect(shown).toBe(drawn);
});

// A closed block (before the reply's last safe boundary, incrementalMarkdown.ts) is drawn once:
// neither a later chunk nor a fade ending draws it again, also while it is the reply's last block
// (a table whose rows the tail holds back, safeTail.ts).
test("a streaming reply draws each closed Markdown block once", () => {
  acpmuxPerf.enabled = true;
  acpmuxPerf.resetRenders();
  try {
    root = createRoot(container);
    render("", true);
    const reply =
      "Intro paragraph with a few words.\n\n```ts\nconst a = 1;\nconst b = 2;\n```\n\n" +
      "Second paragraph that keeps going for a while.\n\n| Step | Clients per second |\n| --- | ---: |\n| one | 5,000 |\n\nThe end of it all.";
    let at = 0;
    for (let end = 6; end < reply.length; end += 6) {
      render(reply.slice(0, end), true);
      frames(at, 3);
      at += 48;
    }
    render(reply, true);
    frames(at, 60);
    expect(acpmuxPerf.renders.get("markdown.closed") ?? 0).toBeGreaterThan(0);
    expect(acpmuxPerf.renders.get("markdown.closed.rerender") ?? 0).toBe(0);
  } finally {
    acpmuxPerf.enabled = false;
    acpmuxPerf.resetRenders();
  }
});

// The last word shows only once the stream ends, a frame after the row stops streaming. Until it
// shows, the reply still reads as streaming: a span the last word closes keeps its streaming form,
// never flashing its raw Markdown ("`bun" for a frame between "bun" in code and "bun test").
test("a reply whose last word closes a code span never shows its backtick", () => {
  root = createRoot(container);
  render("", true);
  render("Run `bun te", true);
  const seen = frames(0, 90);
  render("Run `bun test`", false);
  seen.push(container.querySelector(".cv-md")?.textContent ?? "");
  seen.push(...frames(90 * 16, 30));
  expect(seen.at(-1)).toBe("Run bun test");
  for (const shown of seen) expect(shown).not.toContain("`");
});

// Text before a tool call ends with no space after its last word. While the agent works on the call,
// no more text comes, and the word must not stay hidden ("Let me check the" for seconds).
test("the last word shows once text stops arriving, while the reply still streams", () => {
  root = createRoot(container);
  render("", true);
  render("Let me check the tests.", true);
  const seen = frames(0, 30);
  expect(seen.at(-1)).toBe("Let me check the");
  seen.push(...frames(30 * 16, 60));
  expect(seen.at(-1)).toBe("Let me check the tests.");
});

/// A stand-in for `prefers-reduced-motion: reduce` that a test turns on and off, as the system
/// setting does while the app runs.
function reducedMotionQuery(initial: boolean) {
  const listeners = new Set<() => void>();
  const query = {
    matches: initial,
    media: "(prefers-reduced-motion: reduce)",
    addEventListener: (_type: string, listener: () => void) => listeners.add(listener),
    removeEventListener: (_type: string, listener: () => void) => listeners.delete(listener),
  };
  Object.assign(dom!.window, { matchMedia: () => query });
  return {
    listeners,
    set(on: boolean) {
      query.matches = on;
      act(() => {
        for (const listener of listeners) listener();
      });
    },
  };
}

/// Display frames whose cancel takes the frame back, as `cancelAnimationFrame` does. `frame(now)`
/// runs the frames still pending and returns the reply's text.
function cancellableFrames() {
  const pending = new Map<number, (now: number) => void>();
  let handles = 0;
  revealFrames.request = (callback) => {
    handles += 1;
    pending.set(handles, callback);
    return handles;
  };
  revealFrames.cancel = (handle) => void pending.delete(handle);
  const frame = (now: number) => {
    clock = now;
    const due = [...pending.values()];
    pending.clear();
    act(() => {
      for (const callback of due) callback(now);
    });
    return container.querySelector(".cv-md")?.textContent ?? "";
  };
  return { pending, frame };
}

// Reduce Motion turned on while a reply streams: the stylesheet follows at once, and so does the
// reveal. The row shows all of the reply in that frame, its frame loop stops and no step is left
// fading; text that arrives later shows whole, as in a row that mounted with Reduce Motion on.
test("turning Reduce Motion on mid-reply shows the whole reply and stops the reveal", () => {
  const motion = reducedMotionQuery(false);
  const { pending, frame } = cancellableFrames();
  const reply = LONG_REPLY.trim();
  root = createRoot(container);
  render("", true);
  render(reply, true);
  const paced = [frame(0), frame(16), frame(32)];
  expect(paced.at(-1)!.length).toBeGreaterThan(0);
  expect(paced.at(-1)!.length).toBeLessThan(reply.length);

  motion.set(true);
  expect(container.querySelector(".cv-md")?.textContent).toBe(reply);
  expect(container.querySelectorAll(".cv-fresh").length).toBe(0);
  expect(pending.size).toBe(0);

  const more = `${reply} The release went out.`;
  render(more, true);
  expect(frame(48)).toBe(more);
  expect(container.querySelectorAll(".cv-fresh").length).toBe(0);
  expect(pending.size).toBe(0);

  act(() => root!.unmount());
  root = undefined;
  expect(motion.listeners.size).toBe(0);
});

// Text can render and have its pending frame cancelled before the reveal reads it. Turning Reduce
// Motion on there shows that text. Turning it off again must pace only what arrives after it,
// never re-reveal from the reveal's older length: what shows never shrinks.
test("Reduce Motion on then off before a frame keeps what shows when later text arrives", () => {
  const motion = reducedMotionQuery(false);
  const { frame } = cancellableFrames();
  root = createRoot(container);
  render("", true);
  render("The checks on the merged head", true);
  frame(0);
  frame(16);
  // Rendered, with its frame still pending when Reduce Motion turns on.
  const shown = `${LONG_REPLY.trim()} and the notes are ready.`;
  render(shown, true);
  motion.set(true);
  expect(container.querySelector(".cv-md")?.textContent).toBe(shown);
  motion.set(false);
  render(`${shown} The release went out.`, true);
  for (let index = 0; index < 20; index++) expect(frame(32 + index * 16).length).toBeGreaterThanOrEqual(shown.length);
});

test("wordEdge ends at a whole word, keeps what shows, and lets a long word through", () => {
  expect(wordEdge("alpha beta gam", 14, false, 0)).toBe(10);
  expect(wordEdge("alpha beta gam", 8, false, 0)).toBe(5);
  // A word whose end has not arrived holds, even when the reveal reached it.
  expect(wordEdge("alpha beta", 10, false, 0)).toBe(5);
  expect(wordEdge("alpha beta", 10, true, 0)).toBe(10);
  // Never less than what already shows.
  expect(wordEdge("alpha beta gam", 8, false, 7)).toBe(7);
  // Chinese, Japanese and Korean write no spaces: each character is whole.
  expect(wordEdge("构建已经通过", 4, false, 0)).toBe(4);
  expect(wordEdge("构建已经通过", 6, false, 0)).toBe(6);
  expect(wordEdge("ビルドは成功", 3, false, 0)).toBe(3);
  expect(wordEdge("빌드 성공", 2, false, 0)).toBe(2);
  const url = `see https://example.com/${"a".repeat(80)}`;
  expect(wordEdge(url, url.length, false, 0)).toBe(url.length);
  // Once part of a long word shows, the rest grows as it arrives, not in 48-character jumps.
  expect(wordEdge(url, 60, false, 53)).toBe(60);
});

test("the turn's end shows the rest of a reply still revealing in the same commit", () => {
  // cmux#50299: the reply's last lines revealed over the frames after the turn's end grew it under the
  // fold that had just settled the turn. The render that ends the turn (TurnEndCut) shows them all.
  root = createRoot(container);
  const text = "The answer has a first sentence. And a second one that is still waiting to show.";
  // The rows each turn ended on (VirtualTranscript): only their identity matters.
  const ended = [undefined, [], []] as const;
  const draw = (streaming: boolean, turn: 0 | 1 | 2, body = text) =>
    act(() => {
      root!.render(
        <TurnEndCut.Provider value={ended[turn]}>
          <RevealedMarkdown text={body} streaming={streaming} artifactIdentity="assistant-1" />
        </TurnEndCut.Provider>,
      );
    });
  draw(true, 0, "");
  draw(true, 0);
  frames(0, 3);
  // The stream ends with its last word still fading in (text shows with its chunk, so all of it is there).
  draw(false, 0);
  expect(container.querySelector(".cv-md")?.textContent).toBe(text);
  // The turn ends: all of it, in this commit, drawn as a finished reply with nothing left fading on a
  // clock of its own (the fold opens its new lines).
  draw(false, 1);
  expect(container.querySelector(".cv-md")?.textContent).toBe(text);
  expect(container.querySelectorAll(".cv-fresh").length).toBe(0);
  expect(frames(64, 1)[0]).toBe(text);
  // A later turn's end changes nothing of a reply that already shows whole.
  frames(64, 30);
  draw(false, 2);
  expect(container.querySelector(".cv-md")?.textContent).toBe(text);
});
