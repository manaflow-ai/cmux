// Frame-by-frame layout shift checks for the agent pane's browser tests. A test records one
// `LayoutFrame` per painted frame (`installPaintedFrames` + `window.cmuxAfterPaint`), with the
// boxes of the parts it names read by `readLayoutBoxes` in the page, then asks
// `findLayoutShifts`/`expectNoLayoutShift` whether any named part jumped between two frames in a
// row. A part that is absent in one of the two frames is not a jump (it came or went); a part that
// changes which element draws it (New Tab's composer handing over to the chat's) is one part when
// the test names both selectors under one key.
import { expect } from "bun:test";

export type LayoutBox = { x: number; y: number; width: number; height: number };
export type LayoutFrame = { at: number; boxes: Record<string, LayoutBox | null> };
export type LayoutShift = {
  part: string;
  /// The index of the frame that drew the jump, and its time from the recording's start.
  frame: number;
  at: number;
  from: LayoutBox;
  to: LayoutBox;
  /// The largest edge move, in CSS px.
  px: number;
};

/// Runs in the page: the box of the first visible element each selector list matches, or null.
/// `parts` maps a part's name to a CSS selector list; `text`, when given for a part, keeps only
/// elements whose text includes it (a sent prompt's row). Pass it to `page.evaluate` or inline it in
/// an after-paint callback (`readLayoutBoxes.toString()`).
export function readLayoutBoxes(
  parts: Record<string, string>,
  text: Record<string, string> = {},
): Record<string, LayoutBox | null> {
  const boxes: Record<string, LayoutBox | null> = {};
  for (const [part, selector] of Object.entries(parts)) {
    let found: LayoutBox | null = null;
    for (const element of Array.from(document.querySelectorAll(selector))) {
      const wanted = text[part];
      if (wanted && !(element.textContent ?? "").includes(wanted)) continue;
      const rect = element.getBoundingClientRect();
      if (rect.width === 0 && rect.height === 0) continue;
      const style = getComputedStyle(element);
      if (style.visibility === "hidden" || style.display === "none" || Number(style.opacity) === 0) continue;
      // What is drawn, not the layout box: an `inset()` clip (a card opening) trims its edges.
      const clip = /^inset\(([^)]*?)(?:\s+round\b[^)]*)?\)$/.exec(style.clipPath.trim());
      const [top = 0, right = top, bottom = top, left = right] = clip
        ? clip[1]
            .trim()
            .split(/\s+/)
            .map((value) => Number.parseFloat(value) || 0)
        : [];
      found = {
        x: Math.round((rect.x + left) * 10) / 10,
        y: Math.round((rect.y + top) * 10) / 10,
        width: Math.round((rect.width - left - right) * 10) / 10,
        height: Math.round((rect.height - top - bottom) * 10) / 10,
      };
      break;
    }
    boxes[part] = found;
  }
  return boxes;
}

/// Puts `readLayoutBoxes` on the page as `window.cmuxReadLayoutBoxes`, before its scripts run, so an
/// after-paint callback can read the boxes on the frame it runs for.
export async function installLayoutBoxes(page: { addInitScript(script: string): Promise<unknown> }): Promise<void> {
  await page.addInitScript(`window.cmuxReadLayoutBoxes = ${readLayoutBoxes.toString()};`);
}

const edgeMove = (from: LayoutBox, to: LayoutBox) =>
  Math.max(
    Math.abs(to.x - from.x),
    Math.abs(to.y - from.y),
    Math.abs(to.x + to.width - (from.x + from.width)),
    Math.abs(to.y + to.height - (from.y + from.height)),
  );

/// Every jump of a named part between two frames in a row larger than `tolerancePx`.
export function findLayoutShifts(
  frames: readonly LayoutFrame[],
  parts: readonly string[],
  tolerancePx = 1,
): LayoutShift[] {
  const shifts: LayoutShift[] = [];
  for (let index = 1; index < frames.length; index++) {
    for (const part of parts) {
      const from = frames[index - 1].boxes[part];
      const to = frames[index].boxes[part];
      if (!from || !to) continue;
      const px = edgeMove(from, to);
      if (px > tolerancePx) shifts.push({ part, frame: index, at: frames[index].at, from, to, px });
    }
  }
  return shifts;
}

export function describeLayoutShifts(shifts: readonly LayoutShift[]): string[] {
  return shifts.map(
    (shift) =>
      `${shift.part} moved ${shift.px.toFixed(1)} px at frame ${shift.frame} (${shift.at.toFixed(0)} ms): ` +
      `${JSON.stringify(shift.from)} -> ${JSON.stringify(shift.to)}`,
  );
}

/// Fails, naming each jump, when any part in `parts` moved more than `tolerancePx` between two
/// painted frames in a row.
export function expectNoLayoutShift(frames: readonly LayoutFrame[], parts: readonly string[], tolerancePx = 1): void {
  expect(describeLayoutShifts(findLayoutShifts(frames, parts, tolerancePx))).toEqual([]);
}

export type LayoutTeleport = {
  /// The part, and the measure of it that teleported (`box.top`, `box.width`, a test's own name).
  part: string;
  /// How far the measure went from the first frame that drew the part to the last, in CSS px.
  travel: number;
  /// The largest single-frame step of the measure, the frame that drew it, and that step's share of `travel`.
  step: number;
  frame: number;
  at: number;
  share: number;
};

/// What `findTeleport` follows: an edge or size of the part's box, or any number a test reads from a
/// frame (one part's offset inside another), undefined on frames that do not draw it.
export type TeleportMeasure =
  | "top"
  | "left"
  | "width"
  | "height"
  | "bottom"
  | ((frame: LayoutFrame) => number | undefined);

const boxMeasure: Record<"top" | "left" | "width" | "height" | "bottom", (box: LayoutBox) => number> = {
  top: (box) => box.y,
  left: (box) => box.x,
  width: (box) => box.width,
  height: (box) => box.height,
  bottom: (box) => box.y + box.height,
};

export type TeleportOptions = { measure?: TeleportMeasure; tolerancePx?: number; maxStepShare?: number };

/// A part that went somewhere else (or took another size) mostly in one frame: a teleport rather than
/// a glide. Unlike `findLayoutShifts`, this follows a part across frames where the element drawing it
/// changes (name both surfaces' selectors under one key), and it allows motion: a glide spreads its
/// travel over many frames, so no single step carries more than `maxStepShare` of it. `measure` picks
/// what is followed, the top by default. Undefined when it travelled no more than `tolerancePx` or
/// moved smoothly.
export function findTeleport(
  frames: readonly LayoutFrame[],
  part: string,
  { measure = "top", tolerancePx = 1, maxStepShare = 0.75 }: TeleportOptions = {},
): LayoutTeleport | undefined {
  const read =
    typeof measure === "function"
      ? measure
      : (frame: LayoutFrame) => {
          const box = frame.boxes[part];
          return box ? boxMeasure[measure](box) : undefined;
        };
  const label = typeof measure === "function" ? part : `${part}.${measure}`;
  const drawn = frames.flatMap((frame, index) => {
    const value = read(frame);
    return value === undefined ? [] : [{ index, at: frame.at, value }];
  });
  if (drawn.length < 2) return undefined;
  const travel = Math.abs(drawn.at(-1)!.value - drawn[0].value);
  if (travel <= tolerancePx) return undefined;
  let worst = { step: 0, frame: 0, at: 0 };
  for (let index = 1; index < drawn.length; index++) {
    const step = Math.abs(drawn[index].value - drawn[index - 1].value);
    if (step > worst.step) worst = { step, frame: drawn[index].index, at: drawn[index].at };
  }
  const share = worst.step / travel;
  return share > maxStepShare ? { part: label, travel, ...worst, share } : undefined;
}

export function describeTeleport(teleport: LayoutTeleport | undefined): string[] {
  if (!teleport) return [];
  return [
    `${teleport.part} travelled ${teleport.travel.toFixed(1)} px, ${(teleport.share * 100).toFixed(0)}% of it ` +
      `(${teleport.step.toFixed(1)} px) in frame ${teleport.frame} (${teleport.at.toFixed(0)} ms)`,
  ];
}

export type HandoverJump = { part: string; frame: number; from: number; to: number; px: number };

/// Steps at one frame, `index` (a surface handing a part to another): for each `[part, measure]`, the
/// change from the last earlier frame that drew it to this one. A handover draws the part where the
/// old surface left it, so any step past `tolerancePx` is a jump the eye sees.
export function findJumpsAt(
  frames: readonly LayoutFrame[],
  index: number,
  checks: readonly (readonly [string, TeleportMeasure])[],
  tolerancePx = 2,
): HandoverJump[] {
  const jumps: HandoverJump[] = [];
  for (const [part, measure] of checks) {
    const read =
      typeof measure === "function"
        ? measure
        : (frame: LayoutFrame) => {
            const box = frame.boxes[part];
            return box ? boxMeasure[measure](box) : undefined;
          };
    const label = typeof measure === "function" ? part : `${part}.${measure}`;
    const to = frames[index] && read(frames[index]);
    let earlier = index - 1;
    while (earlier >= 0 && read(frames[earlier]) === undefined) earlier--;
    const from = earlier >= 0 ? read(frames[earlier]) : undefined;
    if (to === undefined || from === undefined) continue;
    if (Math.abs(to - from) > tolerancePx) jumps.push({ part: label, frame: index, from, to, px: Math.abs(to - from) });
  }
  return jumps;
}

export function describeJumps(jumps: readonly HandoverJump[]): string[] {
  return jumps.map(
    (jump) => `${jump.part} jumped ${jump.px.toFixed(1)} px at frame ${jump.frame}: ${jump.from} -> ${jump.to}`,
  );
}

/// Fails, naming each, when a handover frame moves or resizes any checked part past `tolerancePx`.
export function expectNoJumpAt(
  frames: readonly LayoutFrame[],
  index: number,
  checks: readonly (readonly [string, TeleportMeasure])[],
  tolerancePx = 2,
): void {
  expect(describeJumps(findJumpsAt(frames, index, checks, tolerancePx))).toEqual([]);
}

/// Fails, naming the frame, when `part` (its `measure`) jumped to its new value instead of moving there.
export function expectNoTeleport(frames: readonly LayoutFrame[], part: string, options?: TeleportOptions): void {
  expect(describeTeleport(findTeleport(frames, part, options))).toEqual([]);
}
