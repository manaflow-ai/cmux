// The chat render pipeline experiment (chatRenderPipeline.experiment.ts, `experiments.chat_render_pipeline`):
// rule R7 of cmuxterm-hq docs/design/chat-render-pipeline.md, "Off-screen rows cost nothing". A settled
// row takes `content-visibility: auto` with `contain-intrinsic-block-size: auto <its indexed height>`,
// so the browser skips its style, layout and paint while it is off screen and holds its place at the
// height the layout already has for it. The streaming row, the live line and the running turn never
// take it: an off-screen row that is skipped keeps its remembered size, so a row that can still grow
// must stay drawn. With the experiment off nothing here changes a row.
import type { CSSProperties } from "react";
import type { AcpmuxRow } from "../model";
import { WORKED } from "./turns";

/// The index of the latest prompt (`user` row): rows above it belong to turns that have ended, the
/// running turn included its prompt and everything under it. 0 when the experiment is off, so no row
/// counts as settled by position and the rows are not scanned.
export function settledBefore(rows: readonly AcpmuxRow[], on: boolean): number {
  if (!on) return 0;
  for (let index = rows.length - 1; index >= 0; index -= 1) if (rows[index]!.kind === "user") return index;
  return 0;
}

const RUNNING = new Set(["pending", "in_progress", "running"]);

/// Whether the row at `index` is settled: a row of an ended turn above the latest prompt, or one the
/// turn's end marked (work folded under "Worked for", an ended turn's card, its footer). Never a row
/// that streams, the live line, a pending row or a call still running.
export function isSettledRow(row: AcpmuxRow, index: number, before: number): boolean {
  if (row.streaming || row.live || row.pending) return false;
  if (row.status !== undefined && RUNNING.has(row.status)) return false;
  if (index < before) return true;
  return row.settled === true || row.ended === true || row.kind === WORKED || row.kind === "turnSummary";
}

/// The height a row's frame holds while the browser skips it, or undefined to draw it as before.
export function settledRowHeight(
  on: boolean,
  row: AcpmuxRow,
  index: number,
  before: number,
  geometry: { heightAt(index: number): number },
): number | undefined {
  if (!on || !isSettledRow(row, index, before)) return undefined;
  return geometry.heightAt(index);
}

/// The row frame's inline style. Without a held height it is exactly the style the frame had before
/// the experiment (`top` and `marginTop`, no other key), so the DOM is unchanged with it off.
export function rowFrameStyle(
  integralTop: number,
  placedTop: number,
  intrinsicHeight: number | undefined,
): CSSProperties {
  const style: CSSProperties = { top: integralTop, marginTop: placedTop - integralTop };
  if (intrinsicHeight === undefined) return style;
  style.contentVisibility = "auto";
  style.containIntrinsicBlockSize = `auto ${intrinsicHeight}px`;
  return style;
}
