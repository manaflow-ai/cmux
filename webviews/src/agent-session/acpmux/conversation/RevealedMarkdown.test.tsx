// l10n-allow-file: test fixture replies, not shipped UI.
// A streaming reply reads like Claude desktop's and Codex's (Leo 2026-10-19: "remove that block
// ascii blinking cursor thing"; whole words from #22339): nothing trails the newest word (no block
// cursor), and the text grows a whole word at a time, each word fading in, never a letter at a time
// or with a partial word at its end. Once the stream ends, all of it shows. The Debug toggle
// agentPane.debug.streamWords off (`data-stream-words="off"`) grows it a character at a time.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { RevealedMarkdown, revealFrames } from "./RevealedMarkdown";
import { StreamReveal, wordEdge } from "../streamReveal";

let dom: JSDOM | undefined;
let root: Root | undefined;
let container: HTMLElement;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const KEYS = ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"];
const savedFrames = { ...revealFrames };
let queued: ((now: number) => void)[] = [];

beforeEach(() => {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
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
});

afterEach(async () => {
  act(() => root?.unmount());
  root = undefined;
  Object.assign(revealFrames, savedFrames);
  // fixed-wait: teardown only; React's scheduled work runs before its window closes
  await new Promise((resolve) => setTimeout(resolve, 20));
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
      for (const callback of pending) callback(from + index * 16);
    });
    seen.push(container.querySelector(".cv-md")?.textContent ?? "");
  }
  return seen;
}

const render = (text: string, streaming: boolean) =>
  act(() => root!.render(<RevealedMarkdown text={text} streaming={streaming} />));

test("a streaming reply grows by whole words with nothing after the last one", () => {
  root = createRoot(container);
  render("", true);
  const reply = "The checks on the merged head are green and the release notes are ready to send";
  // Deltas cut words in half, as Claude's do.
  const deltas = ["The che", "cks on the mer", "ged head are gr", "een and the release no", "tes are ready to se"];
  let text = "";
  const seen: string[] = [];
  let clock = 0;
  for (const delta of deltas) {
    text += delta;
    render(text, true);
    seen.push(...frames(clock, 12));
    clock += 12 * 16;
  }
  // Frames until just before the last delta is StreamReveal.stallMs old: until then "se" (of
  // "send") has arrived but is not a whole word yet (after it, the last word shows; see below).
  seen.push(...frames(clock, 24));
  clock += 24 * 16;
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
  frames(clock, 30);
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
  frames(30 * 16, 8);
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

test("with the Debug toggle off, a reply grows a character at a time", () => {
  dom!.window.document.documentElement.dataset.streamWords = "off";
  root = createRoot(container);
  render("", true);
  render("Hello there wor", true);
  const shown = frames(0, 90);
  // The partial word shows: the reveal reached the end of what arrived.
  expect(shown.at(-1)).toBe("Hello there wor");
  // On the way there it showed parts of words.
  expect(shown).toContain("Hello there w");
});

/// Runs a display frame `gap` ms after the one before for each of `gaps`, from `from`; returns how
/// many ran a reveal step (StreamReveal.advance), the frames that commit.
function steps(from: number, gaps: number[]): number {
  const advance = StreamReveal.prototype.advance;
  let count = 0;
  StreamReveal.prototype.advance = function (this: StreamReveal, ...args: Parameters<typeof advance>) {
    count += 1;
    return advance.apply(this, args);
  };
  try {
    let now = from;
    for (const gap of gaps) {
      now += gap;
      const pending = queued;
      queued = [];
      act(() => {
        for (const callback of pending) callback(now);
      });
    }
  } finally {
    StreamReveal.prototype.advance = advance;
  }
  return count;
}

const LONG_REPLY = "The checks on the merged head are green and the notes are ready. ".repeat(30);

// WebKit's frame times are whole milliseconds and jitter: a 14 or 15 ms frame follows a 17 to 19
// ms one. Each frame is still a 60 Hz display frame, and one with no step is a frame the reply did
// not grow while text waited (the streaming-text harness counted 64 to 119 a reply in WebKit).
test("on a 60 Hz display the reveal steps on every frame, with WebKit's jittery frame times", () => {
  root = createRoot(container);
  render("", true);
  render(LONG_REPLY, true);
  const gaps = [17, 19, 14, 17, 15, 18, 16, 17, 14, 19, 17, 16, 15, 18];
  expect(steps(0, gaps)).toBe(gaps.length);
});

// Fades run on the compositor, so a faster display commits no more than 60 times a second.
test("on a 120 Hz display the reveal steps on every other frame", () => {
  root = createRoot(container);
  render("", true);
  render(LONG_REPLY, true);
  const frameGaps = (count: number) => Array.from({ length: count }, () => 1000 / 120);
  // The loop learns the display's frame time over its first few frames.
  steps(0, frameGaps(8));
  expect(steps(8000 / 120, frameGaps(12))).toBe(6);
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
