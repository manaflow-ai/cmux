// l10n-allow-file: test fixture thoughts, not shipped UI.
// A long thought folds once done (behind the Debug toggle agentPane.debug.foldLongThoughts, on by
// default in the app): while it streams, a long one holds Codex's seven-line viewport
// (agentPane.debug.liveThoughtViewport), and once done a thought taller than about one transcript
// viewport (never less than THOUGHT_FOLD_MIN_PX; with agentPane.debug.thoughtFoldThreshold "codex",
// THOUGHT_LIVE_PX) folds to one line that opens to its text: "Thought for 12s", or with the Debug
// choice agentPane.debug.thoughtHeader "preview", "Thought" and its first line. The reader's toggle
// always wins over the fold; the toggle animates the height, the automatic fold snaps (as Codex's
// does), and Reduce Motion animates nothing. Off, a thought shows in full (Leo 2026-10-13, #20330).
import { afterEach, beforeEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AcpmuxActivity } from "../model";
import {
  THOUGHT_FOLD_MIN_PX,
  THOUGHT_LIVE_PX,
  ThoughtRow,
  thoughtDuration,
  thoughtLayout,
  thoughtParts,
  thoughtPreview,
  type ThoughtFoldThreshold,
  type ThoughtHeader,
} from "./ThoughtRow";
import { foldMotion } from "./fold";

let dom: JSDOM | undefined;
let root: Root | undefined;
let container: HTMLElement;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const layout = { ...thoughtLayout };
const motion = { ...foldMotion };
/// The fold's duration token as the page resolves it (conversation.css `--cv-fold-duration`).
const FOLD_MS = 190;
/// The thought's drawn height, the transcript viewport's, the Debug toggle and Reduce Motion.
let height = 0;
let viewport = 600;
let enabled = true;
let reduce = false;
let header: ThoughtHeader = "duration";
/// The live viewport's Debug toggle, and the text's whole height (0: only `height` counts).
let live = true;
let content = 0;
let threshold: ThoughtFoldThreshold = "viewport";
type Animated = { keyframes: Keyframe[]; options: KeyframeAnimationOptions; finish: () => void };
let animations: Animated[] = [];

beforeEach(() => {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  // JSDOM has no Web Animations: record each one, finished by the test.
  (dom.window.HTMLElement.prototype as unknown as { animate: unknown }).animate = function (
    keyframes: Keyframe[],
    options: KeyframeAnimationOptions,
  ) {
    const animation = { onfinish: null as null | (() => void), cancel() {} };
    animations.push({ keyframes, options, finish: () => act(() => animation.onfinish?.()) });
    return animation;
  };
  height = 0;
  viewport = 600;
  enabled = true;
  reduce = false;
  header = "duration";
  live = true;
  content = 0;
  // The tests below this file's "every finished thought" block check the older Debug choices.
  threshold = "viewport";
  animations = [];
  thoughtLayout.threshold = () => threshold;
  thoughtLayout.header = () => header;
  thoughtLayout.liveViewport = () => live;
  thoughtLayout.contentHeight = () => content;
  thoughtLayout.height = () => height;
  thoughtLayout.viewport = () => viewport;
  thoughtLayout.enabled = () => enabled;
  foldMotion.reducedMotion = () => reduce;
  foldMotion.duration = () => FOLD_MS;
  foldMotion.easing = () => "ease-out";
  container = dom.window.document.getElementById("root")!;
});

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  Object.assign(thoughtLayout, layout);
  Object.assign(foldMotion, motion);
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

const LONG = Array.from({ length: 30 }, (_, index) => `Step ${index + 1}: check the retry path.`).join("\n");
const thought = (text = LONG): AcpmuxActivity => ({ kind: "thought", text });

function render(item: AcpmuxActivity, streaming: boolean, id: string) {
  act(() => {
    root ??= createRoot(container);
    root.render(<ThoughtRow id={id} item={item} streaming={streaming} />);
  });
}
const toggle = () => container.querySelector<HTMLButtonElement>("button[aria-expanded]");
const body = () => container.querySelector(".cv-thought__body");
const click = () => act(() => toggle()!.click());
/// Whether a done thought `drawn` px tall folds in a `view` px transcript.
function folds(drawn: number, view: number, id: string): boolean {
  height = drawn;
  viewport = view;
  render(thought(), false, id);
  const folded = toggle() !== null;
  act(() => root!.unmount());
  root = undefined;
  return folded;
}

test("with the Debug toggle off, a long thought shows in full as before", () => {
  enabled = false;
  height = 5000;
  render(thought(), false, "off:0");
  expect(toggle()).toBeNull();
  expect(body()).toBeNull();
  expect(container.querySelector(".cv-thought__text")?.textContent).toBe(LONG);
});

test("with the live viewport off, a done thought folds once taller than the transcript's viewport", () => {
  live = false;
  expect(folds(599, 600, "view-1:0")).toBe(false);
  expect(folds(600, 600, "view-2:0")).toBe(false);
  expect(folds(601, 600, "view-3:0")).toBe(true);
});

test("with the live viewport off, a tiny pane folds only thoughts taller than the floor", () => {
  live = false;
  expect(folds(THOUGHT_FOLD_MIN_PX - 1, 200, "floor-1:0")).toBe(false);
  expect(folds(THOUGHT_FOLD_MIN_PX, 200, "floor-2:0")).toBe(false);
  expect(folds(THOUGHT_FOLD_MIN_PX + 1, 200, "floor-3:0")).toBe(true);
});

test("with the live viewport on, a thought it clipped folds once done, even under the transcript's height", () => {
  // An 800px pane: a 300px thought streams clipped to 140px, then folds rather than growing.
  height = THOUGHT_LIVE_PX;
  content = 300;
  viewport = 800;
  render(thought(), true, "band:0");
  expect(row()?.classList.contains("is-live")).toBe(true);
  render(thought(), false, "band:0");
  expect(toggle()?.getAttribute("aria-expanded")).toBe("false");
  expect(body()).toBeNull();
  act(() => root!.unmount());
  root = undefined;
  // A thought the viewport never clipped stays in full.
  content = 0;
  expect(folds(THOUGHT_LIVE_PX, 800, "band-short:0")).toBe(false);
  expect(folds(THOUGHT_LIVE_PX + 1, 800, "band-over:0")).toBe(true);
});

test("a folded thought over a minute reads its minutes and seconds", () => {
  height = 900;
  render({ ...thought(), startedAt: 0, endedAt: 65_400 }, false, "minutes:0");
  expect(toggle()?.textContent).toBe("Thought for 1m 5s");
});

test("with the live viewport off and the Debug choice codex, a done thought folds once taller than seven lines", () => {
  live = false;
  threshold = "codex";
  expect(folds(THOUGHT_LIVE_PX, 600, "codex-1:0")).toBe(false);
  expect(folds(THOUGHT_LIVE_PX + 1, 600, "codex-2:0")).toBe(true);
  // The transcript's viewport no longer counts.
  expect(folds(THOUGHT_LIVE_PX + 1, 2000, "codex-3:0")).toBe(true);
});

test("a folded thought reads how long the agent thought, without its text", () => {
  height = 900;
  render({ ...thought(), startedAt: 1_000, endedAt: 13_400 }, false, "for:0");
  expect(toggle()?.getAttribute("aria-expanded")).toBe("false");
  expect(toggle()?.textContent).toBe("Thought for 12s");
  expect(body()).toBeNull();
  click();
  expect(toggle()?.textContent).toBe("Thought for 12s");
  expect(body()?.textContent).toBe(LONG);
});

test("a folded thought that is undated or under a second reads Thought", () => {
  height = 900;
  render(thought(), false, "undated:0");
  expect(toggle()?.textContent).toBe("Thought");
  act(() => root!.unmount());
  root = undefined;
  render({ ...thought(), startedAt: 1_000, endedAt: 1_900 }, false, "short:0");
  expect(toggle()?.textContent).toBe("Thought");
});

test("a thought's duration never goes negative when its events came out of order", () => {
  expect(thoughtDuration({ ...thought(), startedAt: 5_000, endedAt: 2_000 })).toBe(0);
  expect(thoughtDuration({ ...thought(), startedAt: 1_000, endedAt: 66_000 })).toBe(65_000);
  expect(thoughtDuration(thought())).toBeUndefined();
});

test("with the Debug choice preview, a folded thought reads Thought and its first line", () => {
  header = "preview";
  height = 900;
  render({ ...thought(), startedAt: 1_000, endedAt: 13_000 }, false, "over:0");
  expect(toggle()?.getAttribute("aria-expanded")).toBe("false");
  expect(toggle()?.textContent).toContain("Thought");
  expect(toggle()?.textContent).not.toContain("Thought for");
  expect(toggle()?.textContent).toContain("Step 1: check the retry path.");
  expect(toggle()?.textContent).not.toContain("Step 2");
  expect(body()).toBeNull();
});

test("a long thought shows in full while it streams and folds only when done, without animating", () => {
  live = false;
  height = 900;
  render(thought(LONG.slice(0, 200)), true, "streaming:0");
  render(thought(), true, "streaming:0");
  expect(toggle()).toBeNull();
  expect(container.querySelector(".cv-thought__text")?.textContent).toBe(LONG);
  render(thought(), false, "streaming:0");
  expect(toggle()?.getAttribute("aria-expanded")).toBe("false");
  // The automatic fold snaps, as Codex's does when the next output starts.
  expect(animations).toEqual([]);
});

const row = () => container.querySelector<HTMLElement>(".cv-thought");
const label = () => container.querySelector(".cv-thought__label")?.textContent;

test("a long thought streaming holds the live viewport and reads Thinking", () => {
  height = THOUGHT_LIVE_PX + 1;
  render(thought(), true, "live:0");
  expect(row()?.classList.contains("is-live")).toBe(true);
  expect(label()).toBe("Thinking");
  expect(toggle()).toBeNull();
  expect(container.querySelector(".cv-thought__text")?.textContent).toBe(LONG);
});

test("a thought no taller than the live viewport streams in full under Thinking, never after Thought", () => {
  height = THOUGHT_LIVE_PX;
  render(thought("I am here, reading the retry helper first."), true, "live-short:0");
  expect(row()?.classList.contains("is-live")).toBe(false);
  // The label on its own line, the text under it: never "Thought I am here" as one sentence.
  expect(row()?.classList.contains("is-full")).toBe(true);
  expect(label()).toBe("Thinking");
  expect(container.querySelector(".cv-thought__text")?.textContent).toBe("I am here, reading the retry helper first.");
  expect(row()?.textContent).not.toContain("Thought");
});

test("with the live viewport's toggle off, or the fold's, a long thought streams in full", () => {
  live = false;
  height = 900;
  render(thought(), true, "live-off:0");
  expect(row()?.classList.contains("is-live")).toBe(false);
  act(() => root!.unmount());
  root = undefined;
  live = true;
  enabled = false;
  render(thought(), true, "fold-off:0");
  expect(row()?.classList.contains("is-live")).toBe(false);
});

test("a thought clipped by the live viewport still folds by its whole height once done", () => {
  // Drawn, the clip is 140px; its text is 900px.
  height = THOUGHT_LIVE_PX;
  content = 900;
  render(thought(), true, "clipped:0");
  expect(row()?.classList.contains("is-live")).toBe(true);
  render(thought(), false, "clipped:0");
  expect(toggle()?.getAttribute("aria-expanded")).toBe("false");
  expect(row()?.classList.contains("is-live")).toBe(false);
});

test("a thought the reader opened stays open as new content arrives and after it scrolls out", () => {
  height = 900;
  render(thought(), false, "opened:0");
  click();
  expect(toggle()?.getAttribute("aria-expanded")).toBe("true");
  expect(body()?.textContent).toBe(LONG);
  // The row draws again for a later step (a new item object holding the same thought).
  render({ ...thought() }, false, "opened:0");
  expect(toggle()?.getAttribute("aria-expanded")).toBe("true");
  // The virtualized transcript unmounts it, then mounts it again.
  act(() => root!.unmount());
  root = undefined;
  render(thought(), false, "opened:0");
  expect(toggle()?.getAttribute("aria-expanded")).toBe("true");
  expect(body()?.textContent).toBe(LONG);
});

test("the reader's toggle plays the shared fold, height and opacity, closing after the text slides away", () => {
  height = 900;
  render(thought(), false, "animated:0");
  click();
  expect(animations.length).toBe(1);
  expect(animations[0]!.options.duration).toBe(FOLD_MS);
  expect(animations[0]!.keyframes[0]).toEqual({ height: "0px", opacity: 0 });
  expect(animations[0]!.keyframes.at(-1)!.opacity).toBe(1);
  click();
  expect(animations.length).toBe(2);
  expect(animations[1]!.keyframes.at(-1)).toEqual({ height: "0px", opacity: 0 });
  // The text stays drawn while it closes, then goes.
  expect(body()).not.toBeNull();
  animations[1]!.finish();
  expect(body()).toBeNull();
  expect(toggle()?.getAttribute("aria-expanded")).toBe("false");
});

test("with Reduce Motion the toggle opens and closes at once", () => {
  reduce = true;
  height = 900;
  render(thought(), false, "reduced:0");
  click();
  expect(body()?.textContent).toBe(LONG);
  click();
  expect(body()).toBeNull();
  expect(animations).toEqual([]);
});

test("with explicit animation off the toggle does not schedule a Web Animation", () => {
  document.documentElement.dataset.agentMotion = "off";
  height = 900;
  render(thought(), false, "off-motion:0");
  click();
  expect(body()?.textContent).toBe(LONG);
  expect(animations).toEqual([]);
});

test("the folded line reads the first line without heading marks", () => {
  expect(thoughtPreview("**Planning the retry fix**\n\nMore detail.")).toBe("Planning the retry fix");
  expect(thoughtPreview("## Check errors\nnext")).toBe("Check errors");
});

// Every finished thought folds to one quiet "Thought for 12s" with no text inline, as Claude Desktop
// and Codex draw it (Leo 2026-10-20: "Thought I am here" read weird); a quiet one draws nothing.
const SUMMARY = "I am here: the retry helper swallows the status, so check how it parses errors.";

test("by default a short finished thought folds to Thought for 12s with no text inline, and opens to it", () => {
  threshold = "every";
  height = 20;
  render({ ...thought(SUMMARY), startedAt: 1_000, endedAt: 13_400 }, false, "every:0");
  expect(toggle()?.getAttribute("aria-expanded")).toBe("false");
  expect(toggle()?.textContent).toBe("Thought for 12s");
  expect(container.textContent).not.toContain("I am here");
  expect(body()).toBeNull();
  click();
  expect(body()?.textContent).toBe(SUMMARY);
});

test("by default a finished thought that took under a second reads Thought, folded", () => {
  threshold = "every";
  height = 20;
  render({ ...thought(SUMMARY), startedAt: 1_000, endedAt: 1_400 }, false, "every-quick:0");
  expect(toggle()?.textContent).toBe("Thought");
  expect(body()).toBeNull();
});

test("an empty, blank or very short quick thought draws no row once done", () => {
  threshold = "every";
  for (const [index, item] of [
    thought(""),
    thought("  \n "),
    { ...thought("I am here"), startedAt: 1_000, endedAt: 1_500 },
    thought("Done."),
  ].entries()) {
    render(item, false, `quiet-${index}:0`);
    expect(container.textContent).toBe("");
    act(() => root!.unmount());
    root = undefined;
  }
  // A short thought the agent spent seconds on still says so.
  render({ ...thought("I am here"), startedAt: 1_000, endedAt: 4_000 }, false, "quiet-long:0");
  expect(toggle()?.textContent).toBe("Thought for 3s");
});

test("a short thought still streaming draws, and folds once done", () => {
  threshold = "every";
  height = 20;
  render({ ...thought(SUMMARY), startedAt: 1_000, endedAt: 1_200 }, true, "every-live:0");
  expect(toggle()).toBeNull();
  expect(container.querySelector(".cv-thought__text")?.textContent).toBe(SUMMARY);
  render({ ...thought(SUMMARY), startedAt: 1_000, endedAt: 6_000 }, false, "every-live:0");
  expect(toggle()?.textContent).toBe("Thought for 5s");
  expect(body()).toBeNull();
});

// Every path names a thought with its time or "Thinking", never with its own first words (Leo
// 2026-10-21: "the way we're rendering it with Thought I am here is prettyy weird").
test("a finished thought shown in full by a Debug choice reads Thought for 12s over its text", () => {
  threshold = "viewport";
  height = 20;
  render({ ...thought(SUMMARY), startedAt: 1_000, endedAt: 13_000 }, false, "full-done:0");
  expect(toggle()).toBeNull();
  expect(row()?.classList.contains("is-full")).toBe(true);
  expect(label()).toBe("Thought for 12s");
  expect(container.querySelector(".cv-thought__text")?.textContent).toBe(SUMMARY);
});

test("an undated finished thought shown in full reads Thought alone over its text", () => {
  threshold = "viewport";
  height = 20;
  render(thought(SUMMARY), false, "full-undated:0");
  expect(label()).toBe("Thought");
  expect(row()?.classList.contains("is-full")).toBe(true);
});

const CODEX = "**Planning the retry fix**\n\nThe helper swallows the status.\n\n**Checking callers**\nTwo call sites.";

test("Codex's reasoning headings are muted titles in the text, never glued after Thought", () => {
  threshold = "every";
  height = 20;
  render({ ...thought(CODEX), startedAt: 0, endedAt: 12_000 }, false, "codex:0");
  expect(toggle()?.textContent).toBe("Thought for 12s");
  click();
  const titles = [...container.querySelectorAll(".cv-thought__title")].map((node) => node.textContent);
  expect(titles).toEqual(["Planning the retry fix", "Checking callers"]);
  expect(body()?.textContent).not.toContain("**");
  expect(body()?.textContent).toContain("The helper swallows the status.");
});

test("a streaming Codex thought reads Thinking, its heading a title under it", () => {
  height = 20;
  render(thought(CODEX), true, "codex-live:0");
  expect(label()).toBe("Thinking");
  expect(container.querySelector(".cv-thought__title")?.textContent).toBe("Planning the retry fix");
  expect(container.textContent).not.toContain("**");
});

test("thoughtParts splits headings from the text around them", () => {
  expect(thoughtParts(CODEX)).toEqual([
    { title: "Planning the retry fix" },
    { text: "The helper swallows the status." },
    { title: "Checking callers" },
    { text: "Two call sites." },
  ]);
  expect(thoughtParts("## Check errors\nnext")).toEqual([{ title: "Check errors" }, { text: "next" }]);
  // Bold inside a line is text, not a heading.
  expect(thoughtParts("Use **retry** here.")).toEqual([{ text: "Use **retry** here." }]);
  expect(thoughtParts("plain\n\ntwo paragraphs")).toEqual([{ text: "plain\n\ntwo paragraphs" }]);
});

test("an empty or redacted thought draws nothing, streaming or done", () => {
  for (const [index, streaming] of [true, false].entries())
    for (const text of ["", "   ", "\n\n"]) {
      render({ ...thought(text), startedAt: 0, endedAt: 12_000 }, streaming, `empty-${index}-${text.length}:0`);
      expect(container.innerHTML).toBe("");
      act(() => root!.unmount());
      root = undefined;
    }
});
