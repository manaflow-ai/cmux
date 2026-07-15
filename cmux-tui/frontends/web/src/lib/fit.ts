export interface TerminalSize {
  cols: number;
  rows: number;
}

// A server size smaller on either axis leaves unused room in this pane. That
// means another client currently owns the shared surface size.
export function isForeignSmaller(current: TerminalSize, proposed: TerminalSize | undefined): boolean {
  if (!proposed) return false;
  if (!Number.isFinite(current.cols) || !Number.isFinite(current.rows)) return false;
  if (!Number.isFinite(proposed.cols) || !Number.isFinite(proposed.rows)) return false;
  return current.cols < proposed.cols || current.rows < proposed.rows;
}

// Decides whether a fit proposal should be applied to the terminal and pushed
// to the server. Returns the size to apply, or null for no-op. Sends only
// originate from local fits (attach replay, pane geometry changes), never from
// applying a server resize, so accepting a foreign size cannot echo back and
// start a resize war between attached clients.
export function nextFitSize(current: TerminalSize, proposed: TerminalSize | undefined): TerminalSize | null {
  if (!proposed) return null;
  if (!Number.isFinite(proposed.cols) || !Number.isFinite(proposed.rows)) return null;
  if (proposed.cols < 2 || proposed.rows < 1) return null;
  if (proposed.cols === current.cols && proposed.rows === current.rows) return null;
  return proposed;
}
