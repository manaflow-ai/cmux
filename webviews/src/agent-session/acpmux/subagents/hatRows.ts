// The composer hat's height in whole rows (SubagentTray.tsx), one state per chat (trayFoldMemory.ts).
// The hat is hidden (only its pull tab shows, TrayPullTab.tsx) or N rows tall: one row is its header
// alone, folded; each row past it is one line of its list. `lastExpandedRows` is the height it last
// had open, so a click on the folded header, or a hide and a restore, goes back to it.
//
// - A drag down from its top bar takes away whole rows and, at one row, stops there. Past it the hat
//   rubber-bands: it gives a little under the pointer (`hatBand`) and, let go past half a row, hides
//   to the pull tab. Let go short of that, it springs back to its one row.
// - A drag up adds whole rows, to as many as it has lines (and never past `HAT_MAX_SHARE` of the
//   window); from the pull tab it brings the hat back a row at a time.
// - A click on the top bar goes between one row and the last height it had open.
// - The arrow keys on the focused top bar add or take away one row.
// - Escape during a drag puts back what the drag started from.
// Pure: no DOM, no clock. The pointer and the store live in hatDrag.ts and trayFoldMemory.ts.

/// The header and the default five lines (subagents.css `--acpmux-tray-lines: 5`).
export const HAT_DEFAULT_ROWS = 6;
/// How far a press moves before it is a drag: a press that moves less is a click.
export const HAT_DRAG_SLOP = 6;

export type HatView = { kind: "hidden" } | { kind: "rows"; rows: number };
export type HatState = {
  readonly view: HatView;
  /// The rows the hat last had open (more than one); unset until the person sizes it.
  readonly lastExpandedRows?: number;
};

/// A chat's hat before the person touches it: folded to its header.
export const HAT_FOLDED: HatState = { view: { kind: "rows", rows: 1 } };

/// The rows the hat shows: 0 hidden.
export const shownRows = (state: HatState): number => (state.view.kind === "hidden" ? 0 : state.view.rows);

/// The rows a click or a restore opens to: the last height it had open, else `fallback` (the default
/// five lines, or the height the person last gave any hat, trayResize.ts).
export const expandedRows = (state: HatState, fallback: number): number =>
  Math.max(2, state.lastExpandedRows ?? fallback);

export type HatAction =
  /// A click on the top bar: one row, or back to the last height it had open.
  | { type: "toggle"; fallback: number }
  /// Opens to its last height (`open`), or folds to its one row: rememberTrayOpen's choice.
  | { type: "open"; open: boolean; fallback: number }
  /// The arrow keys on the focused top bar: one row more or less, between 1 and `max`.
  | { type: "step"; by: 1 | -1; max: number }
  /// A drag's rows, as it moves (0: hidden).
  | { type: "drag"; rows: number }
  /// Back to the pull tab.
  | { type: "hide" }
  /// Back from the pull tab: folded, or open at its last height.
  | { type: "show"; open: boolean; fallback: number }
  /// The rim's double-click: the default height again.
  | { type: "reset" };

const withRows = (state: HatState, rows: number): HatState => {
  const view: HatView = rows <= 0 ? { kind: "hidden" } : { kind: "rows", rows };
  // A hide keeps the last height it had open; an open height becomes it.
  const lastExpandedRows = rows > 1 ? rows : state.lastExpandedRows;
  if (sameView(state.view, view) && lastExpandedRows === state.lastExpandedRows) return state;
  return lastExpandedRows === undefined ? { view } : { view, lastExpandedRows };
};

const sameView = (a: HatView, b: HatView) =>
  a.kind === b.kind && (a.kind === "hidden" || a.rows === (b as { rows: number }).rows);

export function hatReducer(state: HatState, action: HatAction): HatState {
  switch (action.type) {
    case "toggle": {
      const rows = shownRows(state);
      return withRows(state, rows > 1 ? 1 : expandedRows(state, action.fallback));
    }
    case "open":
      if (state.view.kind === "hidden") return state;
      if (action.open === state.view.rows > 1) return state;
      return withRows(state, action.open ? expandedRows(state, action.fallback) : 1);
    case "step": {
      if (state.view.kind === "hidden") return state;
      // From the rows it draws: a height kept from a hat with more lines than this one has counts as all of them.
      const max = Math.max(1, action.max);
      const rows = Math.min(state.view.rows, max);
      return withRows(state, Math.min(Math.max(1, rows + action.by), max));
    }
    case "drag":
      return withRows(state, Math.max(0, Math.round(action.rows)));
    case "hide":
      return withRows(state, 0);
    case "show":
      if (state.view.kind !== "hidden") return state;
      return withRows(state, action.open ? expandedRows(state, action.fallback) : 1);
    case "reset":
      // It forgets the height it had open; an open hat takes the default five lines at once.
      return state.view.kind === "rows" && state.view.rows > 1
        ? { view: { kind: "rows", rows: HAT_DEFAULT_ROWS } }
        : { view: state.view };
  }
}

/// A drag's start: where it began (`bar`, the hat's top bar or rim; `pill`, the pull tab), the rows
/// it started from (0 from the pull tab), one row's height and the most rows the hat can take.
export type HatDrag = {
  readonly origin: "bar" | "pill";
  readonly startRows: number;
  readonly rowHeight: number;
  readonly maxRows: number;
};

/// Where a drag is after the pointer moved `down` px (negative: up): the hat's rows (0: hidden) and,
/// past its one row, how far it gives under the pointer (`band`, px, always less than a row).
export function hatDragAt(drag: HatDrag, down: number): { rows: number; band: number; past: number } {
  const row = Math.max(1, drag.rowHeight);
  const max = Math.max(1, drag.maxRows);
  // From the pull tab the hat comes back a row at a time and never goes below hidden.
  if (drag.origin === "pill") {
    const rows = Math.min(Math.max(0, Math.round(-down / row)), max);
    return { rows, band: 0, past: 0 };
  }
  const start = Math.min(Math.max(1, drag.startRows), max);
  const reach = start - down / row;
  // Whole rows, never past one row down: past it is the rubber band.
  const rows = Math.min(Math.max(1, Math.round(reach)), max);
  const past = reach < 1 ? (1 - reach) * row : 0;
  return { rows, band: hatBand(past, row), past };
}

/// The rubber band: how far the hat gives (px) for `past` px of pointer travel past its one row.
/// It follows the pointer at first and stiffens, never reaching a whole row (UIScrollView's curve).
export function hatBand(past: number, row: number): number {
  if (past <= 0 || row <= 0) return 0;
  return row * (1 - 1 / ((past * 0.55) / row + 1));
}

/// Where a drag lands when the pointer lets go: past half a row beyond the one row, hidden; else the
/// rows it reached (from the pull tab, 0 stays hidden).
export function hatDragEnd(drag: HatDrag, down: number): number {
  const at = hatDragAt(drag, down);
  if (drag.origin === "bar" && at.past >= drag.rowHeight / 2) return 0;
  return at.rows;
}

/// The most rows a hat with `lines` lines takes: its header and every line, and never more than
/// `share` of a `viewport` px tall window.
export function hatMaxRows(lines: number, rowHeight: number, viewport: number, share: number): number {
  const fits = rowHeight > 0 && viewport > 0 ? Math.floor((viewport * share) / rowHeight) : lines + 1;
  return Math.max(1, Math.min(lines + 1, fits));
}

/// The rows a dragged list height (trayResize.ts, px) reads as: its lines and the header.
export const rowsForHeight = (height: number | undefined, rowHeight: number): number | undefined =>
  height === undefined || rowHeight <= 0 ? undefined : Math.max(2, 1 + Math.round(height / rowHeight));
