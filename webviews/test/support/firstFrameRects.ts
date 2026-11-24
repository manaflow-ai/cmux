// The first-frame recorder: what a transcript row painted on its first frame, and every painted
// frame after it on which the row or a part of it has another box (Leo, 2026-11-22, of a "started
// working" line: "there's like a secondary animation that shifts as it recalculates to shrink
// stuff ... with better designs this won't happen").
//
// After each painted frame (support/paintedFrames.ts) it reads every row the transcript draws: the
// row's own size, and each part of it that carries a class, as x, y, width and height from the
// row's corner, and the room between the row and the row right above it. A part is named by its
// row's id and its path of class names, so a part React draws again is the same part. The first
// frame a part is read on is its first painted frame; any later frame where its box differs from
// that one by more than half a pixel is a shift, counted with the pixels, the frames, and the
// record that was last sent before it (`mark`).
import type { Page } from "playwright";

export type RectShift = {
  /// The row's id and the part's path of class names inside it ("" is the row itself).
  row: string;
  part: string;
  /// x, y, width, height on the first painted frame and on the last frame read.
  first: number[];
  last: number[];
  /// The most each of x, y, width and height was off its first frame, in px.
  most: number[];
  /// Painted frames whose box differed from the frame before.
  frames: number;
  /// From the part's first painted frame to its last change, in ms.
  spanMs: number;
  /// The marks its changes followed, each with the ms since that mark.
  after: string[];
};

export type RectReport = {
  frames: number;
  rows: number;
  parts: number;
  shifts: RectShift[];
};

declare global {
  interface Window {
    cmuxFirstFrameRects?: { mark(label: string): void; stop(): RectReport };
  }
}

/// Starts reading. `rowSelector` finds the rows; `ignore` is a selector for parts that are not
/// judged (a clock that counts up, say), each with its reason where the test names it.
export async function startFirstFrameRects(page: Page, rowSelector: string, ignore = ""): Promise<void> {
  await page.evaluate(
    ({ rowSelector, ignore }) => {
      type Seen = {
        row: string;
        part: string;
        first: number[];
        last: number[];
        most: number[];
        frames: number;
        firstAt: number;
        lastAt: number;
        after: string[];
      };
      const seen = new Map<string, Seen>();
      const rowIds = new Set<string>();
      let frames = 0;
      let mark = { label: "start", at: performance.now() };
      const round = (value: number) => Math.round(value * 10) / 10;
      const first = (element: Element) =>
        typeof element.className === "string" ? (element.className.trim().split(/\s+/)[0] ?? "") : "";
      const name = (element: Element) => {
        const own = first(element);
        const twins = element.parentElement
          ? [...element.parentElement.children].filter((other) => first(other) === own)
          : [];
        return twins.length > 1 ? `${own}[${twins.indexOf(element)}]` : own;
      };
      const read = (now: number) => {
        frames += 1;
        let above: { id: string; at: number; bottom: number } | undefined;
        for (const row of document.querySelectorAll<HTMLElement>(rowSelector)) {
          const id = row.dataset.rowId ?? "";
          rowIds.add(id);
          const box = row.getBoundingClientRect();
          const parts: [string, number[]][] = [["", [0, 0, round(box.width), round(box.height)]]];
          // The room over the row, while the same row stays right above it: a row that is placed
          // again moves against its neighbour though nothing inside it does.
          const at = Number(row.getAttribute("aria-posinset"));
          if (above && at === above.at + 1)
            parts.push([`(room under ${above.id})`, [0, round(box.top - above.bottom), 0, 0]]);
          above = { id, at, bottom: box.bottom };
          const walk = (element: Element, path: string, depth: number) => {
            for (const child of element.children) {
              if (child instanceof SVGElement && !(child instanceof SVGSVGElement)) continue;
              if (ignore && child.matches(ignore)) continue;
              const own = name(child);
              const next = own ? `${path}${path ? " > " : ""}${own}` : path;
              if (own) {
                const rect = child.getBoundingClientRect();
                // A part with no box (display: none, or contents) has nothing painted to shift.
                if (rect.width > 0 || rect.height > 0)
                  parts.push([
                    next,
                    [round(rect.left - box.left), round(rect.top - box.top), round(rect.width), round(rect.height)],
                  ]);
              }
              if (depth < 8 && !(child instanceof SVGElement)) walk(child, next, depth + 1);
            }
          };
          walk(row, "", 0);
          for (const [part, rect] of parts) {
            const key = `${id}\n${part}`;
            const prior = seen.get(key);
            if (!prior) {
              seen.set(key, {
                row: id,
                part,
                first: rect,
                last: rect,
                most: [0, 0, 0, 0],
                frames: 0,
                firstAt: now,
                lastAt: now,
                after: [],
              });
              continue;
            }
            if (rect.some((value, at) => Math.abs(value - prior.last[at]!) > 0.5)) {
              prior.frames += 1;
              prior.lastAt = now;
              const note = `${mark.label}+${Math.round(now - mark.at)}ms`;
              if (prior.after.length < 6 && !prior.after.some((had) => had.startsWith(`${mark.label}+`)))
                prior.after.push(note);
              prior.last = rect;
            }
            prior.most = prior.most.map((most, at) => Math.max(most, round(Math.abs(rect[at]! - prior.first[at]!))));
          }
        }
        return true;
      };
      const stop = window.cmuxAfterPaint(() => read(performance.now()));
      window.cmuxFirstFrameRects = {
        mark: (label) => {
          mark = { label, at: performance.now() };
        },
        stop: () => {
          stop();
          const shifts = [...seen.values()]
            .filter((part) => part.most.some((most) => most > 0.5))
            .map(({ firstAt, lastAt, ...part }) => ({ ...part, spanMs: Math.round(lastAt - firstAt) }));
          return { frames, rows: rowIds.size, parts: seen.size, shifts };
        },
      };
    },
    { rowSelector, ignore },
  );
}

/// Names what is sent next, so a shift says which record it followed and how long after.
export const markFirstFrameRects = (page: Page, label: string): Promise<void> =>
  page.evaluate((label) => window.cmuxFirstFrameRects!.mark(label), label);

/// Lets `ms` of painted frames pass.
export const paintedFor = (page: Page, ms: number): Promise<void> =>
  page.evaluate(
    (ms) =>
      new Promise<void>((resolve) => {
        const start = performance.now();
        window.cmuxAfterPaint(() => {
          if (performance.now() - start < ms) return true;
          resolve();
          return false;
        });
      }),
    ms,
  );

export const stopFirstFrameRects = (page: Page): Promise<RectReport> =>
  page.evaluate(() => window.cmuxFirstFrameRects!.stop());

/// One line per shifted part, worst first, for a test's log and its failure message.
export function shiftLines(report: RectReport): string[] {
  const worst = (shift: RectShift) => Math.max(...shift.most);
  return [...report.shifts]
    .sort((a, b) => worst(b) - worst(a))
    .map(
      (shift) =>
        `${shift.row} | ${shift.part || "(row)"} | first ${shift.first.join(",")} | last ${shift.last.join(",")} | most ${shift.most.join(",")} px | ${shift.frames} frames over ${shift.spanMs} ms | after ${shift.after.join(" ")}`,
    );
}

/// The numbers a before/after table quotes: parts that shifted, the most px, and the most frames
/// any one part shifted on.
export function shiftTotals(report: RectReport): { parts: number; px: number; frames: number } {
  return {
    parts: report.shifts.length,
    px: Math.max(0, ...report.shifts.map((shift) => Math.max(...shift.most))),
    frames: Math.max(0, ...report.shifts.map((shift) => shift.frames)),
  };
}
