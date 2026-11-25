// l10n-allow-file: diagnostic words for the flicker log, never shown in the pane.
// A chat page's first load, judged frame by frame in the field as bench/first-load-after-restart.bench.ts
// judges it on the fleet (firstLoadFrames.ts `classifyFrames`): did the first painted frame stay, or did the
// composer or the bottom row move, or the pane blank, before it settled. One `first-load` flicker record per
// document (Leo, 2026-11-16, after a restart: "and then it layout shifted as it drew and tried to settle").
// Before this the ring file had no line for it: WebKit, which draws the chat when Chromium did not start,
// reports no layout-shift entries, and the page wrote none of its own.
//
// It reads the layer on top in each frame that could have changed (the drawn copy's shadow root while it
// shows, chatSnapshot/paint.ts, else the live page): the composer's box and the rows in view, by id and top.
// Bounded: it ends QUIET_MS after the last change once the copy is gone, or at WATCH_MS, and only while the
// page is shown; a page at rest wakes nothing for it (`watchFirstLoad`).
// No chat text goes out: counts, times and short words.
import { classifyFrames, type FrameRecord, type FrameRow } from "./firstLoadFrames";
import { SNAPSHOT_HOST_TAG } from "./chatSnapshot/shared";

/// The performance mark App.tsx sets when it first tells the host the page shows the chat
/// (`pane.painted`): the host shows the page from then, so what moves after it is what the reader saw.
export const PANE_PAINTED_MARK = "cmux-chat:painted";

/// The longest a first load is watched, from navigation.
export const WATCH_MS = 20_000;
/// A first load is over once nothing in view changed this long, with no copy over the page.
export const QUIET_MS = 2_000;

/// What the record says: `copy` whether a drawn copy showed first; `first` when content first painted and
/// `settled` when the final state first painted (ms from navigation); `shifts` frames that moved the
/// composer or the bottom row; `blank` frames with no row after content; `why` the first shift's kind.
/// `painted` when the page told the host it shows the chat (ms from navigation, -1 before it never
/// did); `seen` the shift frames from then on, the ones the reader saw (the host covers the page
/// until then); `seenWhy`, `seenAt` (ms after `painted`) and `seenPx` (how far, rounded) of the first.
export type FirstLoadFields = {
  copy: boolean;
  frames: number;
  first: number;
  settled: number;
  shifts: number;
  blank: number;
  why: string;
  painted: number;
  seen: number;
  seenWhy: string;
  seenAt: number;
  seenPx: number;
};

/// How far a shift reason's box moved: its trailing coordinate pair ("... 120.0 -> 98.5"). A row
/// replaced, or the composer coming or going, names no distance: 0. Row ids hold digits too, so only
/// the pair around the arrow is read.
function movedPx(why: string): number {
  const pair = /(-?\d+(?:\.\d+)?) -> (-?\d+(?:\.\d+)?)$/.exec(why);
  return pair ? Math.round(Number(pair[2]) - Number(pair[1])) : 0;
}

/// The kind of a shift reason, with no row id in it.
function kindOf(why: string | undefined): string {
  if (!why) return "";
  if (why.startsWith("composer")) return why.split(" ").slice(0, 2).join(" ");
  return why.includes("replaced") ? "bottom row replaced" : "bottom row moved";
}

/// The judged load from its frames, or undefined when no content ever painted. `painted`: when the
/// page told the host it shows the chat (PANE_PAINTED_MARK), if it did.
export function firstLoadFields(frames: FrameRecord[], painted?: number): FirstLoadFields | undefined {
  const metrics = classifyFrames(frames);
  if (metrics.firstContentMs === null) return undefined;
  const seen = painted === undefined ? [] : metrics.shiftAt.filter((shift) => frames[shift.index]!.t >= painted);
  return {
    painted: painted === undefined ? -1 : Math.round(painted),
    seen: seen.length,
    seenWhy: kindOf(seen[0]?.why),
    seenAt: seen[0] && painted !== undefined ? Math.round(frames[seen[0].index]!.t - painted) : -1,
    seenPx: seen[0] ? movedPx(seen[0].why) : 0,
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
///
/// It reads a frame only when something could have moved: a DOM change (attributes too), a scroll, a resize,
/// an image or font load, a transition or animation start, or (where the engine has it) a `layout-shift`
/// entry. After a read that changed, or that showed no row after content, it reads the next frame too, so a
/// box that moves with no DOM change (a transition) is followed frame by frame until a frame repeats the one
/// before. The load is over once nothing changed for QUIET_MS (with no copy over the page) or at WATCH_MS:
/// the first event after that records it, as does the page going hidden or away, so a page at rest arms no
/// timer and no frame for it. Before, it read every frame until QUIET_MS after the last change, and a chat
/// switch counted as a change: 78 to 95 frame callbacks in the 5 s at rest after a switch
/// (bench/chat-switch.bench.ts `idle_wakeups`, 4 to 5 without it). `frames` counts the frames read.
export function watchFirstLoad(win: Window, record: (fields: FirstLoadFields) => void): void {
  const doc = win.document;
  if (doc.visibilityState !== "visible") return;
  const frames: FrameRecord[] = [];
  let last = "";
  let changedAt = 0;
  let content = false;
  let copyShown = false;
  let done = false;
  let pending: number | undefined;
  const stops: (() => void)[] = [];
  const finish = () => {
    if (done) return;
    done = true;
    if (pending !== undefined) win.cancelAnimationFrame(pending);
    pending = undefined;
    for (const stop of stops) stop();
    const painted = win.performance.getEntriesByName?.(PANE_PAINTED_MARK, "mark")[0]?.startTime;
    const fields = firstLoadFields(frames, painted);
    if (fields) record(fields);
  };
  const over = (now: number) => now >= WATCH_MS || (content && !copyShown && now - changedAt >= QUIET_MS);
  const read = () => {
    pending = undefined;
    const now = win.performance.now();
    if (doc.visibilityState !== "visible") return finish();
    const frame = readFrame(doc, now);
    const next = signature(frame);
    const changed = next !== last;
    const blank = content && frame.rows.length === 0;
    if (changed || blank) frames.push(frame);
    if (changed) {
      last = next;
      changedAt = now;
    }
    if (frame.rows.length > 0) content = true;
    copyShown = frame.copyShown;
    if (now >= WATCH_MS) return finish();
    if (changed || blank) pending = win.requestAnimationFrame(read);
  };
  const wake = () => {
    if (done) return;
    if (over(win.performance.now())) return finish();
    pending ??= win.requestAnimationFrame(read);
  };
  const listen = (
    target: Pick<EventTarget, "addEventListener" | "removeEventListener">,
    type: string,
    run: () => void,
  ) => {
    target.addEventListener(type, run, { capture: true, passive: true });
    stops.push(() => target.removeEventListener(type, run, { capture: true }));
  };

  const mutations = new (win as Window & typeof globalThis).MutationObserver(wake);
  mutations.observe(doc.documentElement, { childList: true, subtree: true, characterData: true, attributes: true });
  stops.push(() => mutations.disconnect());
  for (const type of ["scroll", "load", "transitionrun", "animationstart"]) listen(doc, type, wake);
  listen(win, "resize", wake);
  if (doc.fonts) listen(doc.fonts, "loadingdone", wake);
  const Observer = (win as Window & typeof globalThis).PerformanceObserver;
  if (Observer?.supportedEntryTypes?.includes("layout-shift"))
    try {
      const shifts = new Observer(wake);
      shifts.observe({ type: "layout-shift", buffered: false });
      stops.push(() => shifts.disconnect());
    } catch {
      // The other triggers still read every change.
    }
  listen(doc, "visibilitychange", () => {
    if (doc.visibilityState !== "visible") finish();
  });
  listen(win, "pagehide", finish);
  pending = win.requestAnimationFrame(read);
}
