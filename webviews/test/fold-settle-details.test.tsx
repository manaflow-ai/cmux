// l10n-allow-file: test fixture labels, not shipped UI.
// A page's <details> opens and closes as one motion on the settle (Leo, 2026-11-07: "they dont
// overshoot but they decelerate at the end. i think that might be the key"): its body's height and
// opacity together, the body drawn until it has folded away and nothing drawn after, and one frame
// under Reduce Motion (agent-session/shared/FoldDetails.tsx over session-info/foldMotion.ts).
import { expect, test } from "bun:test";
import { FoldDetails } from "../src/agent-session/shared/FoldDetails";
import { click, expectSettle, fold, reduceMotion, render, useFoldPage } from "./foldSettleHarness";

useFoldPage();

const details = () => fold.container.querySelector("details")!;
const summary = () => fold.container.querySelector("summary")!;
const body = () => fold.container.querySelector<HTMLElement>(".fold-details__body")!;

function page() {
  render(
    <FoldDetails summary="Exact sizes">
      <p>one</p>
      <p>two</p>
    </FoldDetails>,
  );
}

test("a details opens and closes with its body's height and opacity on the settle", () => {
  page();
  expect(details().open).toBe(false);
  click(summary());
  expect(details().open).toBe(true);
  expect(fold.animations.length).toBe(1);
  const [opening] = fold.animations;
  expectSettle(opening);
  expect(opening!.target).toBe(body());
  expect(opening!.keyframes[0]).toEqual({ height: "0px", opacity: 0 });
  expect(opening!.keyframes.at(-1)!.opacity).toBe(1);
  opening!.finish();
  expect(body().dataset.folding).toBeUndefined();
  expect(body().style.overflow).toBe("");

  click(summary());
  expect(fold.animations.length).toBe(2);
  const closing = fold.animations[1]!;
  expectSettle(closing);
  expect(closing.keyframes.at(-1)).toEqual({ height: "0px", opacity: 0 });
  // Drawn open while it folds away, clipped, then closed on the frame it ends.
  expect(details().open).toBe(true);
  expect(body().style.overflow).toBe("clip");
  closing.finish();
  expect(details().open).toBe(false);
  expect(body().style.overflow).toBe("");
  // Nothing more runs or mounts after the motion ends.
  expect(fold.animations.length).toBe(2);
});

test("a details closed mid-open goes back from where it is drawn", () => {
  page();
  click(summary());
  click(summary());
  expect(fold.animations.length).toBe(2);
  // Its start is the height drawn then, not its full height or nothing.
  expect(fold.animations[1]!.keyframes[0]!.height).toBe(`${body().offsetHeight}px`);
});

test("a details opens and closes in one frame under Reduce Motion", () => {
  reduceMotion();
  page();
  click(summary());
  expect(details().open).toBe(true);
  click(summary());
  expect(details().open).toBe(false);
  expect(fold.animations).toEqual([]);
});
