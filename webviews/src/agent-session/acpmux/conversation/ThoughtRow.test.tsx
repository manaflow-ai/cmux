// l10n-allow-file: test fixture thoughts, not shipped UI.
// A thought folds once done: while it streams, a long one holds Codex's seven-line viewport, and
// once done every thought (or, with agentPane.debug.thoughtFoldThreshold "viewport" or "codex", one
// taller than THOUGHT_LIVE_PX) folds to one line that opens to its text: "Thought for 12s", or with
// the Debug choice agentPane.debug.thoughtHeader "preview", "Thought" and its first line. The
// reader's toggle always wins over the fold; the toggle animates the height, the automatic fold
// snaps (as Codex's does), and Reduce Motion animates nothing.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AcpmuxActivity } from "../model";
import { StepThought, ThoughtRow } from "./ThoughtRow";
import {
  THOUGHT_LIVE_PX,
  thoughtDuration,
  thoughtLayout,
  thoughtLine,
  THOUGHT_LINE_CHARS,
  thoughtParts,
  thoughtPreview,
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
// A closed thought's one line of words (Lucas, 2026-11-06); opened, its label.
const preview = () => toggle()?.querySelector(".cv-thought__preview")?.textContent;
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

test("an opened thought over a minute reads its minutes and seconds", () => {
  height = 900;
  render({ ...thought(), startedAt: 0, endedAt: 65_400 }, false, "minutes:0");
  click();
  expect(toggle()?.textContent).toBe("Thought for 1m 5s");
});

test("with the Debug choice codex, a done thought folds once taller than seven lines", () => {
  threshold = "codex";
  expect(folds(THOUGHT_LIVE_PX, "codex-1:0")).toBe(false);
  expect(folds(THOUGHT_LIVE_PX + 1, "codex-2:0")).toBe(true);
});

test("a folded thought reads its words on one line; opened, how long the agent thought", () => {
  height = 900;
  render({ ...thought(), startedAt: 1_000, endedAt: 13_400 }, false, "for:0");
  expect(toggle()?.getAttribute("aria-expanded")).toBe("false");
  expect(preview()).toBe(thoughtLine(LONG));
  expect(toggle()?.querySelector(".cv-tool__icon svg")).not.toBeNull();
  expect(body()).toBeNull();
  click();
  expect(toggle()?.textContent).toBe("Thought for 12s");
  expect(body()?.textContent).toBe(LONG);
});

test("an opened thought that is undated or under a second reads Thought", () => {
  height = 900;
  render(thought(), false, "undated:0");
  click();
  expect(toggle()?.textContent).toBe("Thought");
  act(() => root!.unmount());
  root = undefined;
  render({ ...thought(), startedAt: 1_000, endedAt: 1_900 }, false, "short:0");
  click();
  expect(toggle()?.textContent).toBe("Thought");
});

test("a thought's duration never goes negative when its events came out of order", () => {
  expect(thoughtDuration({ ...thought(), startedAt: 5_000, endedAt: 2_000 })).toBe(0);
  expect(thoughtDuration({ ...thought(), startedAt: 1_000, endedAt: 66_000 })).toBe(65_000);
  expect(thoughtDuration(thought())).toBeUndefined();
});

test("with the Debug choice preview, an opened thought reads Thought, not its time", () => {
  header = "preview";
  height = 900;
  render({ ...thought(), startedAt: 1_000, endedAt: 13_000 }, false, "over:0");
  expect(toggle()?.getAttribute("aria-expanded")).toBe("false");
  expect(preview()).toBe(thoughtLine(LONG));
  expect(body()).toBeNull();
  click();
  expect(toggle()?.textContent).toBe("Thought");
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

// Every finished thought folds to one quiet line, the brain glyph and its words (Lucas,
// 2026-11-06; never "Thought" glued to them, Leo 2026-10-20); opened, "Thought for 12s" over
// its text. A quiet one draws nothing.
const SUMMARY = "I am here: the retry helper swallows the status, so check how it parses errors.";

test("by default a short finished thought folds to its words, and opens to Thought for 12s over them", () => {
  threshold = "every";
  height = 20;
  render({ ...thought(SUMMARY), startedAt: 1_000, endedAt: 13_400 }, false, "every:0");
  expect(toggle()?.getAttribute("aria-expanded")).toBe("false");
  expect(preview()).toBe(SUMMARY);
  expect(toggle()?.textContent).not.toContain("Thought");
  expect(body()).toBeNull();
  click();
  expect(toggle()?.textContent).toBe("Thought for 12s");
  expect(body()?.textContent).toBe(SUMMARY);
});

test("by default a finished thought that took under a second folds, and opened reads Thought", () => {
  threshold = "every";
  height = 20;
  render({ ...thought(SUMMARY), startedAt: 1_000, endedAt: 1_400 }, false, "every-quick:0");
  expect(preview()).toBe(SUMMARY);
  expect(body()).toBeNull();
  click();
  expect(toggle()?.textContent).toBe("Thought");
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
  // A short thought the agent spent seconds on still draws, and opened says how long.
  render({ ...thought("I am here"), startedAt: 1_000, endedAt: 4_000 }, false, "quiet-long:0");
  expect(preview()).toBe("I am here");
  click();
  expect(toggle()?.textContent).toBe("Thought for 3s");
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

test("Codex's reasoning headings are muted titles in the text, never glued after Thought", () => {
  threshold = "every";
  height = 20;
  render({ ...thought(CODEX), startedAt: 0, endedAt: 12_000 }, false, "codex:0");
  // Closed, the headings' marks are gone from the one line.
  expect(preview()).toBe("Planning the retry fix The helper swallows the status. Checking callers Two call sites.");
  click();
  expect(toggle()?.textContent).toBe("Thought for 12s");
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

// A thought inside an opened group holds its line where the reader clicked while its text opens or
// closes under it, as every other row does (Lucas, 2026-11-06: the line slid away from the pointer,
// so the same spot no longer closed it).
test("a step thought's click asks the transcript to hold its line, opening and closing", () => {
  const holds: string[] = [];
  container.addEventListener(ANCHORED_COLLAPSE_EVENT, (event) => {
    event.preventDefault();
    holds.push((event.target as HTMLElement).className);
  });
  act(() => {
    root ??= createRoot(container);
    root.render(<StepThought id="step-hold:0" item={{ ...thought(SUMMARY), startedAt: 0, endedAt: 4_000 }} />);
  });
  expect(toggle()?.getAttribute("aria-expanded")).toBe("false");
  click();
  expect(holds).toHaveLength(1);
  expect(holds[0]).toContain("cv-step-thought");
  expect(toggle()?.getAttribute("aria-expanded")).toBe("true");
  expect(body()?.textContent).toBe(SUMMARY);
  click();
  expect(holds).toHaveLength(2);
  expect(toggle()?.getAttribute("aria-expanded")).toBe("false");
});

test("a closed thought's line holds at most THOUGHT_LINE_CHARS, so its button's name stays short", () => {
  // A thought of thousands of characters named its whole text as the button's accessible name.
  const huge = Array.from({ length: 400 }, (_, index) => `Line ${index}: weigh the next step.`).join("\n");
  const line = thoughtLine(huge);
  expect(line.length).toBeLessThanOrEqual(THOUGHT_LINE_CHARS + 1);
  expect(line.endsWith("\u2026")).toBe(true);
  expect(line.startsWith("Line 0: weigh the next step. Line 1:")).toBe(true);
  // A short thought reads whole, with no mark of a cut.
  expect(thoughtLine("**Plan**\nRead the file.")).toBe("Plan Read the file.");
});
