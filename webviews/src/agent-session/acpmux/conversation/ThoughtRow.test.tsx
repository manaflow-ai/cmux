// l10n-allow-file: test fixture thoughts, not shipped UI.
// A long thought folds once done (behind the Debug toggle agentPane.debug.foldLongThoughts, off by
// default): it shows in full while it streams, and once done a thought taller than about one
// transcript viewport (never less than THOUGHT_FOLD_MIN_PX) folds to one line that opens to its
// text. The reader's toggle always wins over the fold; the toggle animates the height, the
// automatic fold snaps (as Codex's does), and Reduce Motion animates nothing. Off, a thought shows
// in full as it always did (Leo 2026-10-13, #20330).
import { afterEach, beforeEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AcpmuxActivity } from "../model";
import { THOUGHT_FOLD_MIN_PX, THOUGHT_FOLD_MS, ThoughtRow, thoughtLayout, thoughtPreview } from "./ThoughtRow";

let dom: JSDOM | undefined;
let root: Root | undefined;
let container: HTMLElement;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const layout = { ...thoughtLayout };
/// The thought's drawn height, the transcript viewport's, the Debug toggle and Reduce Motion.
let height = 0;
let viewport = 600;
let enabled = true;
let reduce = false;
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
  animations = [];
  thoughtLayout.height = () => height;
  thoughtLayout.viewport = () => viewport;
  thoughtLayout.enabled = () => enabled;
  thoughtLayout.reducedMotion = () => reduce;
  container = dom.window.document.getElementById("root")!;
});

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  Object.assign(thoughtLayout, layout);
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

test("a done thought folds once it is taller than the transcript's viewport, not at its height", () => {
  expect(folds(599, 600, "view-1:0")).toBe(false);
  expect(folds(600, 600, "view-2:0")).toBe(false);
  expect(folds(601, 600, "view-3:0")).toBe(true);
});

test("a tiny pane folds only thoughts taller than the floor", () => {
  expect(folds(THOUGHT_FOLD_MIN_PX - 1, 200, "floor-1:0")).toBe(false);
  expect(folds(THOUGHT_FOLD_MIN_PX, 200, "floor-2:0")).toBe(false);
  expect(folds(THOUGHT_FOLD_MIN_PX + 1, 200, "floor-3:0")).toBe(true);
});

test("a folded thought reads its first line", () => {
  height = 900;
  render(thought(), false, "over:0");
  expect(toggle()?.getAttribute("aria-expanded")).toBe("false");
  expect(toggle()?.textContent).toContain("Step 1: check the retry path.");
  expect(toggle()?.textContent).not.toContain("Step 2");
  expect(body()).toBeNull();
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

test("the reader's toggle animates the height over 200 ms, closing after the text slides away", () => {
  height = 900;
  render(thought(), false, "animated:0");
  click();
  expect(animations.length).toBe(1);
  expect(animations[0]!.options.duration).toBe(THOUGHT_FOLD_MS);
  expect(animations[0]!.keyframes[0]).toEqual({ height: "0px" });
  click();
  expect(animations.length).toBe(2);
  expect(animations[1]!.keyframes.at(-1)).toEqual({ height: "0px" });
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

test("the folded line reads the first line without heading marks", () => {
  expect(thoughtPreview("**Planning the retry fix**\n\nMore detail.")).toBe("Planning the retry fix");
  expect(thoughtPreview("## Check errors\nnext")).toBe("Check errors");
});
