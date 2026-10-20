// l10n-allow-file: test fixture replies, not shipped UI.
// A streaming reply reads like Claude desktop's and Codex's (Leo 2026-10-19: "remove that block
// ascii blinking cursor thing"): nothing trails the newest word (no block cursor), and the text
// grows a whole word at a time, each word fading in, never a letter at a time or with a partial
// word at its end. Once the stream ends, all of it shows.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { RevealedMarkdown, revealFrames } from "./RevealedMarkdown";
import { wordEdge } from "../streamReveal";

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
  // The reveal catches up once the deltas stop (StreamReveal drains a stall).
  seen.push(...frames(clock, 90));
  clock += 90 * 16;
  expect(container.querySelector(".cv-caret")).toBeNull();
  const words = new Set(reply.split(" "));
  for (const shown of seen) {
    if (!shown) continue;
    // Every word on screen is a whole word of the reply; the one still arriving never shows.
    for (const word of shown.split(" ")) expect(words.has(word)).toBe(true);
    expect(shown.endsWith(" ")).toBe(false);
  }
  // "se" (of "send") has arrived but is not a whole word yet.
  expect(seen.at(-1)).toBe("The checks on the merged head are green and the release notes are ready to");
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
  // Still fading: a frame within FADE_MS of the last step.
  const shown = frames(0, 90);
  expect(shown.at(-1)).toBe("Hello there");
  render("Hello there world, again", true);
  frames(90 * 16, 4);
  const fresh = [...container.querySelectorAll(".cv-fresh")].map((span) => span.textContent ?? "");
  // Only whole words fade in: " world," arrived whole; "again" may still grow.
  expect(
    fresh
      .join("")
      .trim()
      .split(/\s+/)
      .every((word) => ["world,", "Hello", "there"].includes(word)),
  ).toBe(true);
  expect(container.querySelector(".cv-md")?.textContent?.startsWith("Hello there")).toBe(true);
});

test("wordEdge ends at a whole word, keeps what shows, and lets a long word through", () => {
  expect(wordEdge("alpha beta gam", 14, false, 0)).toBe(10);
  expect(wordEdge("alpha beta gam", 8, false, 0)).toBe(5);
  // A word whose end has not arrived holds, even when the reveal reached it.
  expect(wordEdge("alpha beta", 10, false, 0)).toBe(5);
  expect(wordEdge("alpha beta", 10, true, 0)).toBe(10);
  // Never less than what already shows.
  expect(wordEdge("alpha beta gam", 8, false, 7)).toBe(7);
  const url = `see https://example.com/${"a".repeat(80)}`;
  expect(wordEdge(url, url.length, false, 0)).toBe(url.length);
});
