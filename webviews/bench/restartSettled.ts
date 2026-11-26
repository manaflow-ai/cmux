// l10n-allow-file: bench numbers, not shipped UI.
// Restart to settled, from one relaunch's painted frames (bench/first-load-after-restart.bench.ts): when the chat
// first showed content, when it settled (the live chat, read from the daemon, is on screen and nothing in view
// moves after), and how many shifts after the first content there were and how far they moved. Leo, 2026-11-22:
// "get that gui agent chat sped up to be nearly as fast as the terminal coming back ... essentially lickety split
// instantly rendered properly, in the right place". Pure, so test/restart-settled.test.ts checks it without a
// browser.
import { type FrameMetrics, type FrameRecord, MOVE_TOLERANCE_PX } from "../src/agent-session/acpmux/firstLoadFrames";

export type RestartSettled = {
  /// The first frame with a transcript row in view, ms from navigation.
  firstContentMs: number | null;
  /// The later of: the live page showing the newest answer, and the first frame of the final state (nothing in view
  /// moves, comes or goes after it). Null when the live chat never showed.
  settledMs: number | null;
  /// Frames after the first content in which something in view moved or was replaced.
  shifts: number;
  /// The furthest a row in both frames or the composer moved in one of those frames, in CSS px (a replaced row
  /// counts as a shift but not here).
  shiftPxMax: number;
  /// The sum of those moves over every shift frame, in CSS px.
  shiftPxSum: number;
  /// Rows that were in view in some frame and are not in view in the last one: drawn, then folded away,
  /// replaced or pushed out (Leo, 2026-11-22: "this rush and barrage of tool calls and message on a sort of
  /// renewed-load of chats. but they get folded/hidden anyways").
  goneRows: number;
  /// Frames that showed at least one of those rows.
  goneFrames: number;
};

/// The rows in view in some frame and not in the last one, and the frames that showed any of them. A row
/// whose words a last-frame row shows is that row under another id (the copy's v1 rows before the row
/// store's), not a gone one. With `turnEnds` (an open turn the run ends) the running turn's own lines, its
/// header and thinking line (turns.ts `working-<prompt>`, `thinking-live`), are not counted: they end with the turn
/// for a watcher too, and what is measured is the work the reload drew that the turn's fold takes away.
export function goneRows(frames: FrameRecord[], turnEnds = false): { rows: number; frames: number } {
  const last = frames.at(-1);
  if (!last) return { rows: 0, frames: 0 };
  const final = new Set(last.rows.map((row) => row.id));
  const finalText = new Set(last.rows.map((row) => row.text).filter((text) => !!text));
  const gone = new Set<string>();
  let shown = 0;
  for (const frame of frames) {
    let any = false;
    for (const row of frame.rows)
      if (!final.has(row.id) && !(row.text && finalText.has(row.text)) && !(turnEnds && liveTurnLine(row.id))) {
        gone.add(row.id);
        any = true;
      }
    if (any) shown += 1;
  }
  return { rows: gone.size, frames: shown };
}

/// The running turn's own header or thinking line (turns.ts WORKING, THINKING), not its work.
export const liveTurnLine = (id: string) => id.startsWith("working-") || id === "thinking-live";

/// How far anything in view moved from `before` to `after`: rows by id, the composer's top and height.
export function movedPx(before: FrameRecord, after: FrameRecord): number {
  let most = 0;
  const tops = new Map(before.rows.map((row) => [row.id, row.top]));
  for (const row of after.rows) {
    const top = tops.get(row.id);
    if (top !== undefined) most = Math.max(most, Math.abs(top - row.top));
  }
  if (before.composer && after.composer)
    most = Math.max(
      most,
      Math.abs(before.composer.top - after.composer.top),
      Math.abs(before.composer.height - after.composer.height),
    );
  return most > MOVE_TOLERANCE_PX ? most : 0;
}

export function restartSettled(
  frames: FrameRecord[],
  metrics: FrameMetrics,
  liveLatestMs: number | null,
  turnEnds = false,
): RestartSettled {
  let shiftPxMax = 0;
  let shiftPxSum = 0;
  for (const { index } of metrics.shiftAt) {
    const px = movedPx(frames[index - 1]!, frames[index]!);
    shiftPxMax = Math.max(shiftPxMax, px);
    shiftPxSum += px;
  }
  const gone = goneRows(frames, turnEnds);
  const settledMs = liveLatestMs === null ? null : Math.max(liveLatestMs, metrics.finalFirstPaintMs ?? liveLatestMs);
  return {
    firstContentMs: metrics.firstContentMs,
    settledMs,
    shifts: metrics.shiftFrames,
    shiftPxMax: Math.round(shiftPxMax * 10) / 10,
    shiftPxSum: Math.round(shiftPxSum * 10) / 10,
    goneRows: gone.rows,
    goneFrames: gone.frames,
  };
}
