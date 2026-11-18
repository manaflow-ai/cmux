// Where a new chat's parts sit on every painted frame, and the browser's own layout-shift entries,
// for the settle checks (agent-pane-new-chat-settles.real.test.ts). The page side runs in the page
// and closes over nothing; reads happen after each frame has painted (paintedFrames.ts).
import type { Page } from "playwright";

/** The parts a new chat must hold still, by name. */
export const SETTLE_PARTS = {
  composer: ".acpmux-main > .acpmux-dock .acpmux-composer-box",
  header: ".acpmux-header",
  pickers: ".acpmux-main > .acpmux-dock .acpmux-chips",
  firstMessage: ".acpmux-user",
  transcript: ".acpmux-main .acpmux-scroll",
  empty: ".acpmux-empty",
  newTab: ".nt-field",
} as const;
export type PartName = keyof typeof SETTLE_PARTS;

export type Box = { x: number; y: number; w: number; h: number };
export type SettleFrame = {
  t: number;
  parts: Partial<Record<PartName, Box>>;
  /** Each picker chip's box and text, left to right. */
  chips: { box: Box; text: string }[];
};
export type ShiftEntry = {
  t: number;
  value: number;
  hadRecentInput: boolean;
  sources: { node: string; from: Box; to: Box }[];
};

declare global {
  interface Window {
    cmuxSettle?: { frames: SettleFrame[]; shifts: ShiftEntry[]; marks: Record<string, number>; stop?: () => void };
  }
}

/** Records layout-shift entries from the page's first frame on (an init script). */
export async function installShiftRecorder(page: Page): Promise<void> {
  await page.addInitScript(() => {
    const settle = (window.cmuxSettle = { frames: [], shifts: [], marks: {} } as NonNullable<Window["cmuxSettle"]>);
    const box = (r: DOMRectReadOnly) => ({ x: r.x, y: r.y, w: r.width, h: r.height });
    const name = (node: Node | null | undefined) => {
      const el = node instanceof Element ? node : node?.parentElement;
      if (!el) return "?";
      const cls = typeof el.className === "string" ? el.className.trim().split(/\s+/).slice(0, 3).join(".") : "";
      return `${el.tagName.toLowerCase()}${cls ? `.${cls}` : ""}`;
    };
    new PerformanceObserver((list) => {
      for (const entry of list.getEntries() as any[]) {
        settle.shifts.push({
          t: entry.startTime,
          value: entry.value,
          hadRecentInput: entry.hadRecentInput,
          sources: (entry.sources ?? []).map((s: any) => ({
            node: name(s.node),
            from: box(s.previousRect),
            to: box(s.currentRect),
          })),
        });
      }
    }).observe({ type: "layout-shift", buffered: true });
  });
}

/** Starts sampling every painted frame's part boxes (after installPaintedFrames). */
export async function startFrameSampler(page: Page): Promise<void> {
  await page.evaluate((parts) => {
    const settle = window.cmuxSettle!;
    const box = (r: DOMRect) => ({
      x: Math.round(r.x * 10) / 10,
      y: Math.round(r.y * 10) / 10,
      w: Math.round(r.width * 10) / 10,
      h: Math.round(r.height * 10) / 10,
    });
    settle.stop = window.cmuxAfterPaint((t) => {
      const frame: SettleFrame = { t, parts: {}, chips: [] };
      for (const [part, selector] of Object.entries(parts)) {
        const el = document.querySelector(selector);
        if (!el) continue;
        const r = el.getBoundingClientRect();
        if (r.width === 0 && r.height === 0) continue;
        (frame.parts as Record<string, unknown>)[part] = box(r);
      }
      const row = document.querySelector(parts.pickers);
      if (row)
        for (const chip of Array.from(row.children)) {
          const r = chip.getBoundingClientRect();
          if (r.width === 0) continue;
          frame.chips.push({ box: box(r), text: (chip.textContent ?? "").trim() });
        }
      settle.frames.push(frame);
    });
  }, SETTLE_PARTS);
}

/** Notes `name` at the page's clock (performance.now), for phases. */
export function mark(page: Page, name: string): Promise<void> {
  return page.evaluate((name) => {
    window.cmuxSettle!.marks[name] = performance.now();
  }, name);
}

export async function collect(page: Page) {
  return page.evaluate(() => {
    const settle = window.cmuxSettle!;
    settle.stop?.();
    return { frames: settle.frames, shifts: settle.shifts, marks: settle.marks };
  });
}

/** A part's move between two frames: the largest change of its edges, in px. */
export function moved(a: Box, b: Box): number {
  return Math.max(
    Math.abs(a.x - b.x),
    Math.abs(a.y - b.y),
    Math.abs(a.x + a.w - (b.x + b.w)),
    Math.abs(a.y + a.h - (b.y + b.h)),
  );
}

export type Shift = { t: number; part: string; from: Box; to: Box; px: number };

/**
 * Every move of a part between consecutive painted frames from `from` on, beyond half a pixel.
 * `grows` lists parts whose bottom edge may move down (content arriving below a fixed top); only
 * their top, left and right must stay.
 */
export function shiftsAfter(frames: SettleFrame[], from: number, grows: PartName[] = []): Shift[] {
  const out: Shift[] = [];
  const after = frames.filter((frame) => frame.t >= from);
  for (let i = 1; i < after.length; i++) {
    const [a, b] = [after[i - 1]!, after[i]!];
    for (const part of Object.keys(b.parts) as PartName[]) {
      const pa = a.parts[part];
      const pb = b.parts[part]!;
      if (!pa) continue;
      const px = grows.includes(part)
        ? Math.max(Math.abs(pa.x - pb.x), Math.abs(pa.y - pb.y), Math.abs(pa.w - pb.w))
        : moved(pa, pb);
      if (px > 0.5) out.push({ t: b.t, part, from: pa, to: pb, px });
    }
    // The picker row's chips: each chip in place, left to right (a chip that changes width moves
    // the ones after it: the row reflowed).
    if (a.chips.length === b.chips.length)
      b.chips.forEach((chip, at) => {
        const px = moved(a.chips[at]!.box, chip.box);
        if (px > 0.5)
          out.push({
            t: b.t,
            part: `chip ${at} (${a.chips[at]!.text} -> ${chip.text})`,
            from: a.chips[at]!.box,
            to: chip.box,
            px,
          });
      });
    else
      out.push({
        t: b.t,
        part: `chips ${a.chips.map((c) => c.text).join("|")} -> ${b.chips.map((c) => c.text).join("|")}`,
        from: a.parts.pickers ?? { x: 0, y: 0, w: 0, h: 0 },
        to: b.parts.pickers ?? { x: 0, y: 0, w: 0, h: 0 },
        px: 0,
      });
  }
  return out;
}

/** The CLS-style score (the sum of layout-shift values) of entries at or after `from`. */
export function scoreAfter(shifts: ShiftEntry[], from: number, to = Infinity): number {
  return shifts.filter((s) => s.t >= from && s.t < to).reduce((sum, s) => sum + s.value, 0);
}
