// l10n-allow-file: diagnostic words for the flicker log, never shown in the pane.
// A chat page's first load, judged frame by frame in the field as bench/first-load-after-restart.bench.ts
// judges it on the fleet (firstLoadFrames.ts `classifyFrames`): did the first painted frame stay, or did the
// composer or the bottom row move, or the pane blank, before it settled. One `first-load` flicker record per
// document (Leo, 2026-11-16, after a restart: "and then it layout shifted as it drew and tried to settle").
// Before this the ring file had no line for it: WebKit, which draws the chat when Chromium did not start,
// reports no layout-shift entries, and the page wrote none of its own.
//
// It reads the layer on top each frame (the drawn copy's shadow root while it shows, chatSnapshot/paint.ts,
// else the live page): the composer's box and the rows in view, by id and top. Bounded: it stops
// QUIET_MS after the last change once the copy is gone, or at WATCH_MS, and only while the page is shown.
// No chat text goes out: counts, times and short words.
import { classifyFrames, type FrameRecord, type FrameRow } from "./firstLoadFrames";
import { SNAPSHOT_HOST_TAG } from "./chatSnapshot/shared";

/// The longest a first load is watched, from navigation.
export const WATCH_MS = 20_000;
/// A first load is over once nothing in view changed this long, with no copy over the page.
export const QUIET_MS = 2_000;

/// What the record says: `copy` whether a drawn copy showed first; `first` when content first painted and
/// `settled` when the final state first painted (ms from navigation); `shifts` frames that moved the
/// composer or the bottom row; `blank` frames with no row after content; `why` the first shift's kind.
export type FirstLoadFields = {
  copy: boolean;
  frames: number;
  first: number;
  settled: number;
  shifts: number;
  blank: number;
  why: string;
};

/// The kind of a shift reason, with no row id in it.
function kindOf(why: string | undefined): string {
  if (!why) return "";
  if (why.startsWith("composer")) return why.split(" ").slice(0, 2).join(" ");
  return why.includes("replaced") ? "bottom row replaced" : "bottom row moved";
}

/// The judged load from its frames, or undefined when no content ever painted.
export function firstLoadFields(frames: FrameRecord[]): FirstLoadFields | undefined {
  const metrics = classifyFrames(frames);
  if (metrics.firstContentMs === null) return undefined;
  return {
    copy: frames.some((frame) => frame.copyShown),
    frames: metrics.frames,
    first: Math.round(metrics.firstContentMs),
    settled: Math.round(metrics.finalFirstPaintMs ?? metrics.firstContentMs),
    shifts: metrics.shiftFrames,
    blank: metrics.blankAfterContent,
    why: kindOf(metrics.shiftAt[0]?.why),
  };
}

/// One frame of `doc` as firstLoadFrames.ts reads it.
export function readFrame(doc: Document, now: number): FrameRecord {
  const drawn = doc.querySelector<HTMLElement>(SNAPSHOT_HOST_TAG);
  const host = drawn && drawn.style.visibility !== "hidden" ? drawn : null;
  const scope: ParentNode = host?.shadowRoot ?? doc;
  const rootHidden = !host && doc.getElementById("root")?.style.opacity === "0";
  const scroller = scope.querySelector<HTMLElement>(".acpmux-scroll");
  const view = rootHidden ? undefined : scroller?.getBoundingClientRect();
  const rows: FrameRow[] = [];
  if (view)
    for (const row of Array.from(scope.querySelectorAll<HTMLElement>(".acpmux-row[data-row-id]"))) {
      const box = row.getBoundingClientRect();
      if (box.height <= 0 || box.bottom <= view.top || box.top >= view.bottom) continue;
      rows.push({ id: row.dataset.rowId ?? "", top: box.top });
    }
  rows.sort((a, b) => a.top - b.top);
  const composer = rootHidden
    ? undefined
    : Array.from(scope.querySelectorAll(".acpmux-composer-box"))
        .map((element) => element.getBoundingClientRect())
        .find((box) => box.height > 0);
  return {
    t: now,
    copyShown: !!host,
    rows,
    composer: composer ? { top: composer.top, height: composer.height } : null,
    scrollTop: scroller && !rootHidden ? scroller.scrollTop : null,
  };
}

const signature = (frame: FrameRecord) =>
  JSON.stringify([
    frame.copyShown,
    frame.rows.map((row) => [row.id, Math.round(row.top)]),
    frame.composer && [Math.round(frame.composer.top), Math.round(frame.composer.height)],
  ]);

/// Watches this document's first load and records it once through `record`. A page loaded hidden (a chat
/// prepared off screen) has no first frame to judge: it records nothing.
export function watchFirstLoad(win: Window, record: (fields: FirstLoadFields) => void): void {
  const doc = win.document;
  if (doc.visibilityState !== "visible") return;
  const frames: FrameRecord[] = [];
  let last = "";
  let changedAt = 0;
  const step = () => {
    const now = win.performance.now();
    if (doc.visibilityState !== "visible") return finish();
    const frame = readFrame(doc, now);
    frames.push(frame);
    const next = signature(frame);
    if (next !== last) {
      last = next;
      changedAt = now;
    }
    const content = frames.some((one) => one.rows.length > 0);
    if (now >= WATCH_MS || (content && !frame.copyShown && now - changedAt >= QUIET_MS)) return finish();
    win.requestAnimationFrame(step);
  };
  const finish = () => {
    const fields = firstLoadFields(frames);
    if (fields) record(fields);
  };
  win.requestAnimationFrame(step);
}
