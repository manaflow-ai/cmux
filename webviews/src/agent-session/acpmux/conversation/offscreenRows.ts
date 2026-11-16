/// Rows mounted away from the view cost nothing to style or lay out until they come near it.
///
/// An older page mounts its rows a few viewports above the reader (VirtualTranscript `history`, the
/// warm rows), 1,000 to 2,400 elements a fling commit, and the first read after the insert paid for
/// styling and laying out all of them, whatever that read was. A row mounted farther from the view
/// than the browser draws ahead (`OFFSCREEN_MARGIN_WINDOWS`) now carries `content-visibility: auto`
/// (conversation.css `OFFSCREEN_ROW_CLASS`): the browser skips its contents until it comes near the
/// viewport, the way Chromium skips an off-screen part of any long page. Its box is the height the
/// transcript placed it at (`contain-intrinsic-height`, the measured or estimated height its index
/// holds), so a read of it in the meantime is that height and no row moves.
///
/// A skipped row is never measured (`skippedRow`): its box is the placed height itself, and taking
/// that for a drawn height would overwrite the estimate with a placeholder (a fixed 60 px trial did,
/// and every row it mounted was then placed 60 px high). It is measured once it renders, still a
/// window or more from the view: the row's ResizeObserver reports it when its rendered height differs
/// from the placed one.
///
/// Only an engine that both skips (content-visibility) and can say a row is skipped (checkVisibility's
/// `contentVisibilityAuto`) and keeps a row's overhanging controls drawn (overflow-clip-margin under
/// the paint containment content-visibility brings) marks rows; any other draws every row as before.

/// The class a row mounted away from the view carries for its whole life (conversation.css).
export const OFFSCREEN_ROW_CLASS = "acpmux-row--offscreen";

/// How far from the view, in window heights, a row must be when it mounts to be skipped: Chromium
/// renders a content-visibility: auto element within 150% of the window's height of the window
/// (transcript-offscreen-rows-skipped.test.ts reads it), so a row mounted closer would render in the
/// same frame anyway. Such a row is measured in its commit as before.
export const OFFSCREEN_MARGIN_WINDOWS = 1.5;

let supported: boolean | undefined;

/// Whether this engine can skip an off-screen row and say it did. Read once per page.
export function skipsOffscreenRows(): boolean {
  if (supported !== undefined) return supported;
  supported = false;
  if (typeof document === "undefined" || typeof CSS === "undefined" || typeof CSS.supports !== "function") return false;
  if (!CSS.supports("content-visibility", "auto") || !CSS.supports("overflow-clip-margin", "1px")) return false;
  const root = document.documentElement as HTMLElement | null;
  if (!root || typeof root.checkVisibility !== "function") return false;
  // An engine that does not know the option ignores it, and would call a skipped row's contents shown.
  let asked = false;
  root.checkVisibility({
    get contentVisibilityAuto() {
      asked = true;
      return false;
    },
  } as CheckVisibilityOptions);
  supported = asked;
  return supported;
}

/// Whether a row placed at [top, top + height) is far enough from the view [viewTop, viewTop +
/// viewHeight) to mount skipped. `windowHeight`: the window's or more (the screen's), which the
/// browser's own margin is a share of; the view lies inside the window, so a row that far from the
/// view is that far from the window.
export function mountsOffscreen(
  top: number,
  height: number,
  viewTop: number,
  viewHeight: number,
  windowHeight: number,
): boolean {
  if (!(viewHeight > 0)) return false;
  const margin = Math.max(windowHeight, viewHeight) * OFFSCREEN_MARGIN_WINDOWS;
  return top + height < viewTop - margin || top > viewTop + viewHeight + margin;
}

/// Whether `row` (a transcript row that mounted offscreen) has its contents skipped now: its height
/// is then only its placed one, never a drawn one. One style read of the row's first child; a row
/// that never mounted offscreen is not read.
export function skippedRow(row: HTMLElement): boolean {
  if (!row.classList.contains(OFFSCREEN_ROW_CLASS)) return false;
  const inside = row.firstElementChild as HTMLElement | null;
  return inside !== null && !inside.checkVisibility({ contentVisibilityAuto: true });
}

/// Tests reset the page-wide answer.
export function resetOffscreenRowsSupportForTest(value?: boolean): void {
  supported = value;
}
