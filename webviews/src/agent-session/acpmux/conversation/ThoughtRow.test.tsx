// l10n-allow-file: test fixture thoughts, not shipped UI.
// A thought folds once done: while it streams, a long one holds Codex's seven-line viewport, and
// once done every thought (or, with agentPane.debug.thoughtFoldThreshold "viewport" or "codex", one
// taller than THOUGHT_LIVE_PX) folds to its own first line, cut with an ellipsis; opening leaves
// that line where it is and unfolds the rest of the text under it (Leo, 2026-11-22: "had the whole
// line be the line? then you expand and it simply shows you the rest"), with how long it took at
// the row's end (not with the Debug choice agentPane.debug.thoughtHeader "preview"). A thought its
// line holds whole opens nothing. The reader's toggle always wins over the fold; the toggle
// animates the height, the automatic fold snaps (as Codex's does), and Reduce Motion animates
// nothing.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AcpmuxActivity } from "../model";
import { StepThought, ThoughtRow } from "./ThoughtRow";
import {
  THOUGHT_LIVE_PX,
  thoughtDuration,
  thoughtHead,
  thoughtLayout,
  THOUGHT_LINE_CHARS,
  thoughtName,
  thoughtParts,
  type ThoughtFoldThreshold,
  type ThoughtHeader,
} from "./thoughtRowModel";
import { foldMotion } from "./fold";
import { ANCHORED_COLLAPSE_EVENT } from "./useAnchoredCollapse";
import { settleReact } from "../../../../test/support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
let container: HTMLElement;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const layout = { ...thoughtLayout };
const motion = { ...foldMotion };
/// The fold's duration token as the page resolves it (conversation.css `--cv-fold-duration`).
const FOLD_MS = 190;
/// The thought's drawn height and Reduce Motion.
let height = 0;
let reduce = false;
let header: ThoughtHeader = "duration";
/// The text's whole height (0: only `height` counts).
let content = 0;
let threshold: ThoughtFoldThreshold = "viewport";
/// Whether the closed line's words run past the one line it shows.
let clipped = false;
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
  reduce = false;
  header = "duration";
  content = 0;
  // The tests below this file's "every finished thought" block check the older Debug choices.
  threshold = "viewport";
  animations = [];
  clipped = false;
  thoughtLayout.cut = () => clipped;
  thoughtLayout.threshold = () => threshold;
  thoughtLayout.header = () => header;
  thoughtLayout.contentHeight = () => content;
  thoughtLayout.height = () => height;
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
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

const LONG = Array.from({ length: 30 }, (_, index) => `Step ${index + 1}: check the retry path.`).join("\n");
/// What opens under the first line.
const REST = LONG.slice(LONG.indexOf("\n") + 1);
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
// A thought's row line: its own first line, closed and open.
const preview = () => container.querySelector(".cv-thought__preview")?.textContent;
/// How long it took, at the row's end.
const time = () => container.querySelector(".cv-thought__time")?.textContent;
/// A row that opens nothing: its line holds the whole thought.
const whole = () => container.querySelector(".cv-thought.is-whole");
const FIRST = "Step 1: check the retry path.";
/// Whether a done thought `drawn` px tall folds.
function folds(drawn: number, id: string): boolean {
  height = drawn;
  render(thought(), false, id);
  const folded = toggle() !== null;
  act(() => root!.unmount());
  root = undefined;
  return folded;
}

test("a thought the live viewport clipped folds once done, even under the transcript's height", () => {
  // A 300px thought streams clipped to 140px, then folds rather than growing.
  height = THOUGHT_LIVE_PX;
  content = 300;
  render(thought(), true, "band:0");
  expect(row()?.classList.contains("is-live")).toBe(true);
  render(thought(), false, "band:0");
  expect(toggle()?.getAttribute("aria-expanded")).toBe("false");
  expect(body()).toBeNull();
  act(() => root!.unmount());
  root = undefined;
  // A thought the viewport never clipped stays in full.
  content = 0;
  expect(folds(THOUGHT_LIVE_PX, "band-short:0")).toBe(false);
  expect(folds(THOUGHT_LIVE_PX + 1, "band-over:0")).toBe(true);
});

test("an opened thought over a minute reads its minutes and seconds at the row's end", () => {
  height = 900;
  render({ ...thought(), startedAt: 0, endedAt: 65_400 }, false, "minutes:0");
  click();
  expect(preview()).toBe(FIRST);
  expect(time()).toBe("1m 5s");
  expect(toggle()?.textContent).not.toContain("Thought");
});

test("with the Debug choice codex, a done thought folds once taller than seven lines", () => {
  threshold = "codex";
  expect(folds(THOUGHT_LIVE_PX, "codex-1:0")).toBe(false);
  expect(folds(THOUGHT_LIVE_PX + 1, "codex-2:0")).toBe(true);
});

test("a folded thought reads its own first line; opened, the same line with the rest under it", () => {
  height = 900;
  render({ ...thought(), startedAt: 1_000, endedAt: 13_400 }, false, "for:0");
  expect(toggle()?.getAttribute("aria-expanded")).toBe("false");
  expect(preview()).toBe(FIRST);
  expect(toggle()?.querySelector(".cv-tool__icon svg")).not.toBeNull();
  expect(toggle()?.querySelector(".cv-tool__chevron")).not.toBeNull();
  expect(body()).toBeNull();
  const line = container.querySelector(".cv-thought__preview");
  click();
  // No word is swapped: the same node holds the same line, the brain stays, and the rest opens.
  expect(container.querySelector(".cv-thought__preview")).toBe(line);
  expect(preview()).toBe(FIRST);
  expect(line?.classList.contains("is-open")).toBe(true);
  expect(toggle()?.querySelector(".cv-tool__icon svg")).not.toBeNull();
  expect(toggle()?.textContent).toBe(`${FIRST}12s`);
  expect(body()?.textContent).toBe(REST);
  // The line and the rest together are the whole thought, in order.
  expect(`${preview()}\n${body()?.textContent}`).toBe(LONG);
});

test("a thought that is undated or took under a second shows no time", () => {
  height = 900;
  render(thought(), false, "undated:0");
  click();
  expect(toggle()?.textContent).toBe(FIRST);
  expect(time()).toBeUndefined();
  act(() => root!.unmount());
  root = undefined;
  render({ ...thought(), startedAt: 1_000, endedAt: 1_900 }, false, "short:0");
  click();
  expect(toggle()?.textContent).toBe(FIRST);
});

test("a thought's duration never goes negative when its events came out of order", () => {
  expect(thoughtDuration({ ...thought(), startedAt: 5_000, endedAt: 2_000 })).toBe(0);
  expect(thoughtDuration({ ...thought(), startedAt: 1_000, endedAt: 66_000 })).toBe(65_000);
  expect(thoughtDuration(thought())).toBeUndefined();
});

test("with the Debug choice preview, a thought shows no time", () => {
  header = "preview";
  height = 900;
  render({ ...thought(), startedAt: 1_000, endedAt: 13_000 }, false, "over:0");
  expect(toggle()?.getAttribute("aria-expanded")).toBe("false");
  expect(preview()).toBe(FIRST);
  expect(body()).toBeNull();
  click();
  expect(toggle()?.textContent).toBe(FIRST);
});

test("a long thought shows in full while it streams and folds only when done, without animating", () => {
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
  expect(body()?.textContent).toBe(REST);
  // The row draws again for a later step (a new item object holding the same thought).
  render({ ...thought() }, false, "opened:0");
  expect(toggle()?.getAttribute("aria-expanded")).toBe("true");
  // The virtualized transcript unmounts it, then mounts it again.
  act(() => root!.unmount());
  root = undefined;
  render(thought(), false, "opened:0");
  expect(toggle()?.getAttribute("aria-expanded")).toBe("true");
  expect(body()?.textContent).toBe(REST);
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

// The morph (Leo, 2026-11-22: "i think we'd likely want a morphing animation to and from thought"):
// a line cut to one line grows to its wrapped height over the fold's time, and shrinks back holding
// its wrapped words until it is one line tall again.
test("a cut line grows to its wrapped height on open and shrinks back on close, over the fold's time", () => {
  const one = "One long line of thought that runs past the row's end and so is cut with an ellipsis.";
  clipped = true;
  const line = () => container.querySelector<HTMLElement>(".cv-thought__preview")!;
  // One line closed (20px), three lines wrapped (60px).
  thoughtLayout.height = (node) => (node.classList.contains("is-open") ? 60 : 20);
  threshold = "every";
  render(thought(one), false, "morph:0");
  // Nothing under the line: the line itself is all there is to open.
  expect(toggle()?.getAttribute("aria-expanded")).toBe("false");
  expect(toggle()?.hasAttribute("aria-controls")).toBe(false);
  click();
  expect(preview()).toBe(one);
  expect(body()).toBeNull();
  const grow = animations.find(({ keyframes }) => "maxHeight" in keyframes[0]!);
  expect(grow?.keyframes).toEqual([
    { height: "20px", maxHeight: "20px" },
    { height: "60px", maxHeight: "60px" },
  ]);
  expect(grow?.options.duration).toBe(FOLD_MS);
  animations = [];
  click();
  const shrink = animations.find(({ keyframes }) => "maxHeight" in keyframes[0]!);
  expect(shrink?.keyframes).toEqual([
    { height: "60px", maxHeight: "60px" },
    { height: "20px", maxHeight: "20px" },
  ]);
  // Its wrapped words stay while it shrinks; the ellipsis comes back at the end.
  expect(line().classList.contains("is-closing")).toBe(true);
  shrink!.finish();
  expect(line().classList.contains("is-closing")).toBe(false);
  expect(toggle()?.getAttribute("aria-expanded")).toBe("false");
});

test("with Reduce Motion the toggle opens and closes at once", () => {
  reduce = true;
  height = 900;
  render(thought(), false, "reduced:0");
  click();
  expect(body()?.textContent).toBe(REST);
  click();
  expect(body()).toBeNull();
  expect(animations).toEqual([]);
});

test("with explicit animation off the toggle does not schedule a Web Animation", () => {
  document.documentElement.dataset.agentMotion = "off";
  height = 900;
  render(thought(), false, "off-motion:0");
  click();
  expect(body()?.textContent).toBe(REST);
  expect(animations).toEqual([]);
});

test("a thought's line is its own first line, a leading heading its words, and the rest is what follows", () => {
  expect(thoughtHead("**Planning the retry fix**\n\nMore detail.")).toEqual({
    line: "Planning the retry fix",
    title: true,
    rest: "More detail.",
    gap: true,
  });
  expect(thoughtHead("## Check errors\nnext")).toEqual({ line: "Check errors", title: true, rest: "next", gap: false });
  expect(thoughtHead("First.\nSecond.\n\nThird.")).toEqual({
    line: "First.",
    title: false,
    rest: "Second.\n\nThird.",
    gap: false,
  });
  expect(thoughtHead("First paragraph.\n\nSecond.")).toEqual({
    line: "First paragraph.",
    title: false,
    rest: "Second.",
    gap: true,
  });
  // Bold inside a line is text, and one line has nothing after it.
  expect(thoughtHead("Use **retry** here.")).toEqual({
    line: "Use **retry** here.",
    title: false,
    rest: "",
    gap: false,
  });
  expect(thoughtHead("")).toEqual({ line: "", title: false, rest: "", gap: false });
});

// Every finished thought folds to one quiet line, the brain glyph and its own first line (Lucas,
// 2026-11-06; never "Thought" glued to its words, Leo 2026-10-20). A quiet one draws nothing.
const SUMMARY = "I am here: the retry helper swallows the status, so check how it parses errors.";

test("a thought its line holds whole has no chevron and does not open", () => {
  threshold = "every";
  height = 20;
  render({ ...thought(SUMMARY), startedAt: 1_000, endedAt: 13_400 }, false, "every:0");
  expect(toggle()).toBeNull();
  expect(container.querySelector("button")).toBeNull();
  expect(whole()?.querySelector(".cv-tool__chevron")).toBeNull();
  expect(whole()?.querySelector(".cv-tool__icon svg")).not.toBeNull();
  expect(preview()).toBe(SUMMARY);
  expect(time()).toBe("12s");
  expect(whole()?.textContent).not.toContain("Thought");
  expect(body()).toBeNull();
});

test("the same thought on a row too narrow for it is cut, and opens to its whole line", () => {
  threshold = "every";
  height = 20;
  clipped = true;
  render({ ...thought(SUMMARY), startedAt: 1_000, endedAt: 1_400 }, false, "every-cut:0");
  expect(whole()).toBeNull();
  expect(toggle()?.getAttribute("aria-expanded")).toBe("false");
  expect(toggle()?.querySelector(".cv-tool__chevron")).not.toBeNull();
  click();
  expect(toggle()?.getAttribute("aria-expanded")).toBe("true");
  expect(toggle()?.textContent).toBe(SUMMARY);
  // Open, it stays a toggle though its wrapped line is no longer cut.
  clipped = false;
  render({ ...thought(SUMMARY), startedAt: 1_000, endedAt: 1_400 }, false, "every-cut:0");
  expect(toggle()?.getAttribute("aria-expanded")).toBe("true");
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
  // A short thought the agent spent seconds on still draws, with how long.
  render({ ...thought("I am here"), startedAt: 1_000, endedAt: 4_000 }, false, "quiet-long:0");
  expect(preview()).toBe("I am here");
  expect(time()).toBe("3s");
});

test("a short thought still streaming draws, and folds once done", () => {
  threshold = "every";
  height = 20;
  render({ ...thought(SUMMARY), startedAt: 1_000, endedAt: 1_200 }, true, "every-live:0");
  expect(toggle()).toBeNull();
  expect(container.querySelector(".cv-thought__text")?.textContent).toBe(SUMMARY);
  render({ ...thought(SUMMARY), startedAt: 1_000, endedAt: 6_000 }, false, "every-live:0");
  expect(preview()).toBe(SUMMARY);
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

test("a leading heading is the row's line; the headings after it are titles in the text under it", () => {
  threshold = "every";
  height = 20;
  render({ ...thought(CODEX), startedAt: 0, endedAt: 12_000 }, false, "codex:0");
  // Closed, the heading's words without its marks.
  expect(preview()).toBe("Planning the retry fix");
  expect(container.querySelector(".cv-thought__preview")?.classList.contains("is-title")).toBe(true);
  click();
  expect(toggle()?.textContent).toBe("Planning the retry fix12s");
  const titles = [...container.querySelectorAll(".cv-thought__title")].map((node) => node.textContent);
  expect(titles).toEqual(["Checking callers"]);
  expect(body()?.classList.contains("is-gap")).toBe(true);
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

// A thought inside an opened group holds its line where the reader clicked while its text opens or
// closes under it, as every other row does (Lucas, 2026-11-06: the line slid away from the pointer,
// so the same spot no longer closed it).
test("a step thought's click asks the transcript to hold its line, opening and closing", () => {
  const holds: string[] = [];
  container.addEventListener(ANCHORED_COLLAPSE_EVENT, (event) => {
    event.preventDefault();
    holds.push((event.target as HTMLElement).className);
  });
  const two = `${SUMMARY}\nThen read the callers.`;
  act(() => {
    root ??= createRoot(container);
    root.render(<StepThought id="step-hold:0" item={{ ...thought(two), startedAt: 0, endedAt: 4_000 }} />);
  });
  expect(toggle()?.getAttribute("aria-expanded")).toBe("false");
  click();
  expect(holds).toHaveLength(1);
  expect(holds[0]).toContain("cv-step-thought");
  expect(toggle()?.getAttribute("aria-expanded")).toBe("true");
  expect(preview()).toBe(SUMMARY);
  expect(body()?.textContent).toBe("Then read the callers.");
  click();
  expect(holds).toHaveLength(2);
  expect(toggle()?.getAttribute("aria-expanded")).toBe("false");
});

test("a step thought with no words to show reads Thought, and opens nothing", () => {
  act(() => {
    root ??= createRoot(container);
    root.render(<StepThought id="step-empty:0" item={{ ...thought(""), startedAt: 0, endedAt: 4_000 }} />);
  });
  expect(toggle()).toBeNull();
  expect(preview()).toBe("Thought");
  expect(whole()?.querySelector(".cv-tool__chevron")).toBeNull();
});

test("a line longer than THOUGHT_LINE_CHARS names its button with its start, so the name stays short", () => {
  // One unbroken line of thousands of characters named its whole text as the button's accessible name.
  const huge = Array.from({ length: 400 }, (_, index) => `Part ${index}: weigh the next step.`).join(" ");
  const name = thoughtName(huge)!;
  expect(name.length).toBeLessThanOrEqual(THOUGHT_LINE_CHARS + 1);
  expect(name.endsWith("\u2026")).toBe(true);
  expect(name.startsWith("Part 0: weigh the next step. Part 1:")).toBe(true);
  // A short line names the button itself.
  expect(thoughtName("Read the file.")).toBeUndefined();
  clipped = true;
  threshold = "every";
  render(thought(huge), false, "huge:0");
  expect(toggle()?.getAttribute("aria-label")).toBe(name);
  expect(preview()).toBe(huge);
});
