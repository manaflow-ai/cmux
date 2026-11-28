export interface TerminalSize {
  cols: number;
  rows: number;
}

// Decides whether a fit proposal should be applied to the terminal and pushed
// to the server. Returns the size to apply, or null for no-op. Sends only
// originate from local fits (attach replay, pane geometry changes), never from
// applying a server resize, so receiving the shared size cannot echo back and
// start a resize war between attached clients.
export function nextFitSize(reported: TerminalSize | null, proposed: TerminalSize | undefined): TerminalSize | null {
  if (!proposed) return null;
  if (!Number.isFinite(proposed.cols) || !Number.isFinite(proposed.rows)) return null;
  if (proposed.cols < 2 || proposed.rows < 1) return null;
  if (proposed.cols === reported?.cols && proposed.rows === reported.rows) return null;
  return proposed;
}
