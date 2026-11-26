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
/// and every row it mounted was then placed 60 px high). Once the page renders it, still a window or
/// more from the view, it drops the class (`onceRendered`), its ResizeObserver reports its rendered
/// height, and it draws exactly as an unmarked row does by the time it shows.
///
/// Only an engine that skips (content-visibility), says when it renders a skipped row (the state
/// change event, and checkVisibility's `contentVisibilityAuto`) and keeps a row's overhanging controls drawn (overflow-clip-margin under
/// the paint containment content-visibility brings) marks rows; any other draws every row as before.

/// The class a row mounted away from the view carries for its whole life (conversation.css).
export const OFFSCREEN_ROW_CLASS = "acpmux-row--offscreen";

/// How far from the view, in window heights, a row must be when it mounts to be skipped. A row closer
/// is measured in its commit as before. Chromium draws a content-visibility: auto element some way
/// ahead of the window anyway (about 2.5 window heights in transcript-offscreen-rows-skipped.test.ts),
/// so a skipped row is drawn and measured well before it shows.
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
  // A row drops the class once rendered (`onceRendered`), so an engine that never says so would keep
  // rows contained in view.
  supported = asked && "oncontentvisibilityautostatechange" in root;
  return supported;
}

/// The marked rows the page has rendered, by their content-visibility state change event. Kept here
/// so that asking whether a row is skipped reads no style: `checkVisibility` forced a style update of
/// the skipped rows on every measure, the top cost of a fling (a fling profile: 18.9 s of 103 s of
/// long tasks), which undid what skipping saved.
const renderedRows = new WeakSet<HTMLElement>();

/// Calls `rendered` once, the first time the page renders `row` (an `OFFSCREEN_ROW_CLASS` row): its
/// content-visibility state change with `skipped` false. Returns the stop; the listener also ends
/// after that one call.
export function onceRendered(row: HTMLElement, rendered: () => void): () => void {
  const listener = (event: Event) => {
    if (event.target !== row || (event as ContentVisibilityAutoStateChangeEvent).skipped) return;
    row.removeEventListener("contentvisibilityautostatechange", listener);
    renderedRows.add(row);
    rendered();
  };
  row.addEventListener("contentvisibilityautostatechange", listener);
  return () => row.removeEventListener("contentvisibilityautostatechange", listener);
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

/// Whether a row placed at `top` with `height` (the thread's coordinates) is out of the view as it
/// mounts, so an entrance on it would play for no one (cmuxterm-hq docs/design/transcript-animation-rules.md,
/// rule 1; Leo, 2026-11-22: "i scroll down, some bullshit ABOVE folds...? and plays an animation!?").
/// Above the view it is unseen whether or not the view follows. Below it only when the reader has
/// scrolled up (`viewHeight` > 0): a followed view (`viewHeight` 0) brings the new tail in, and that
/// row keeps its entrance.
export function entersUnseen(top: number, height: number, viewTop: number, viewHeight: number): boolean {
  if (top + height <= viewTop + 1) return true;
  return viewHeight > 0 && top >= viewTop + viewHeight - 1;
}

/// Whether `row` (a transcript row that mounted offscreen) has its contents skipped now: its height
/// is then only its placed one, never a drawn one. It is skipped from its mount until the page says it
/// rendered it (`onceRendered`); no style or layout is read.
export function skippedRow(row: HTMLElement): boolean {
  return row.classList.contains(OFFSCREEN_ROW_CLASS) && !renderedRows.has(row);
}
