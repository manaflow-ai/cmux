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
      found = {
        x: Math.round(rect.x * 10) / 10,
        y: Math.round(rect.y * 10) / 10,
        width: Math.round(rect.width * 10) / 10,
        height: Math.round(rect.height * 10) / 10,
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
  part: string;
  /// How far the part's top travelled from the first frame that drew it to the last, in CSS px.
  travel: number;
  /// The largest single-frame step of its top, the frame that drew it, and that step's share of `travel`.
  step: number;
  frame: number;
  at: number;
  share: number;
};

/// A part whose top went somewhere else mostly in one frame: a teleport rather than a glide. Unlike
/// `findLayoutShifts`, this follows a part across frames where the element drawing it changes (name
/// both surfaces' selectors under one key), and it allows motion: a glide spreads its travel over
/// many frames, so no single step carries more than `maxStepShare` of it. Undefined when the part
/// travelled no more than `tolerancePx` or moved smoothly.
export function findTeleport(
  frames: readonly LayoutFrame[],
  part: string,
  { tolerancePx = 1, maxStepShare = 0.75 }: { tolerancePx?: number; maxStepShare?: number } = {},
): LayoutTeleport | undefined {
  const drawn = frames.flatMap((frame, index) => {
    const box = frame.boxes[part];
    return box ? [{ index, at: frame.at, top: box.y }] : [];
  });
  if (drawn.length < 2) return undefined;
  const travel = Math.abs(drawn.at(-1)!.top - drawn[0].top);
  if (travel <= tolerancePx) return undefined;
  let worst = { step: 0, frame: 0, at: 0 };
  for (let index = 1; index < drawn.length; index++) {
    const step = Math.abs(drawn[index].top - drawn[index - 1].top);
    if (step > worst.step) worst = { step, frame: drawn[index].index, at: drawn[index].at };
  }
  const share = worst.step / travel;
  return share > maxStepShare ? { part, travel, ...worst, share } : undefined;
}

export function describeTeleport(teleport: LayoutTeleport | undefined): string[] {
  if (!teleport) return [];
  return [
    `${teleport.part} travelled ${teleport.travel.toFixed(1)} px, ${(teleport.share * 100).toFixed(0)}% of it ` +
      `(${teleport.step.toFixed(1)} px) in frame ${teleport.frame} (${teleport.at.toFixed(0)} ms)`,
  ];
}

/// Fails, naming the frame, when `part` jumped to its new place instead of moving there.
export function expectNoTeleport(
  frames: readonly LayoutFrame[],
  part: string,
  options?: { tolerancePx?: number; maxStepShare?: number },
): void {
  expect(describeTeleport(findTeleport(frames, part, options))).toEqual([]);
}
