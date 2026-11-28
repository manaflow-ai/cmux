/// Rows far above a followed view keep their place and skip their paint.
///
/// A followed transcript mounts a few screens of history above the reader (VirtualTranscript
/// `history`, HISTORY_VIEWPORTS; the chat-open harness holds three or more screens mounted). Every
/// streamed frame then painted and composited all of them again: at 2,000 chats in the perf cron's
/// chat-100k-flat bench, a long chat's stream spent about 4x the paint and compositor update of an
/// empty one, the worst of its CPU ratios. Unmounting them is not an option (the harness, and a
/// reader who scrolls up finds them drawn). A row that ends more than `SHELF_VIEWPORTS` window heights
/// above a followed view is instead shelved: it stays mounted at its placed height (`height`, the
/// measured or estimated height its index holds, so no row moves), and `content-visibility: hidden`
/// skips its contents' style, layout and paint until it is unshelved. It unshelves the commit the view
/// stops following, or comes within that distance, well before it shows.
///
/// A shelved row is never measured (`shelvedRow`): its box is the placed height, not a drawn one.

/// How far above a followed view, in window heights, a row must end to be shelved.
export const SHELF_VIEWPORTS = 1;

let supported: boolean | undefined;

/// Whether this engine can skip a row's contents. Read once per page.
export function shelvesRows(): boolean {
  if (supported !== undefined) return supported;
  supported =
    typeof CSS !== "undefined" && typeof CSS.supports === "function" && CSS.supports("content-visibility", "hidden");
  return supported;
}

/// The offset above which a followed view shelves rows (`shelvedHeight`), or -Infinity for none.
export function shelfLine(following: boolean, viewTop: number, viewHeight: number): number {
  if (!following || viewHeight <= 0 || !shelvesRows()) return -Infinity;
  return viewTop - viewHeight * SHELF_VIEWPORTS;
}

/// The height a row placed at `top`, `height` high, is shelved at: its placed height when it ends
/// above `line` (`shelfLine`), else 0 (drawn). A row placed 0 high draws nothing to skip.
export function shelvedHeight(top: number, height: number, line: number): number {
  return height > 0 && top + height < line ? height : 0;
}

/// Whether `row` is shelved now: its height is then only its placed one, never a drawn one.
export function shelvedRow(row: HTMLElement): boolean {
  return row.dataset.shelved !== undefined;
}
