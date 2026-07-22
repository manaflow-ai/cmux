import type {
  Id,
  RenderCursor,
  RenderDeltaEvent,
  RenderRow,
  RenderStateEvent,
} from "cmux/browser";

export interface RenderModel {
  surface: Id;
  size: { cols: number; rows: number };
  cursor: RenderCursor;
  defaultFg: string;
  defaultBg: string;
  scrollbackRows: number;
  rows: readonly RenderRow[];
}

function emptyRow(row: number): RenderRow {
  return { row, runs: [] };
}

function normalizeRows(rows: readonly RenderRow[], height: number): readonly RenderRow[] {
  const normalized = Array.from({ length: height }, (_, row) => emptyRow(row));
  for (const candidate of rows) {
    if (!Number.isInteger(candidate.row) || candidate.row < 0 || candidate.row >= height) continue;
    normalized[candidate.row] = { row: candidate.row, runs: [...candidate.runs] };
  }
  return normalized;
}

export function applySnapshot(snapshot: RenderStateEvent): RenderModel {
  return {
    surface: snapshot.surface,
    size: { ...snapshot.size },
    cursor: { ...snapshot.cursor },
    defaultFg: snapshot.default_fg,
    defaultBg: snapshot.default_bg,
    scrollbackRows: snapshot.scrollback_rows,
    rows: normalizeRows(snapshot.rows, snapshot.size.rows),
  };
}

export function applyDelta(model: RenderModel, delta: RenderDeltaEvent): RenderModel {
  // Attachment streams are ordered, but a stale event can still be buffered
  // after a surface switch. Never let it mutate the replacement attachment.
  if (delta.surface !== model.surface) return model;

  const size = delta.size === undefined ? model.size : { ...delta.size };
  const replacesViewport = delta.full || delta.size !== undefined;
  let rows = model.rows;
  if (replacesViewport) {
    rows = normalizeRows(delta.rows, size.rows);
  } else if (delta.rows.length > 0) {
    const next = [...model.rows];
    for (const candidate of delta.rows) {
      if (!Number.isInteger(candidate.row) || candidate.row < 0 || candidate.row >= size.rows) continue;
      next[candidate.row] = { row: candidate.row, runs: [...candidate.runs] };
    }
    rows = next;
  }

  return {
    surface: model.surface,
    size,
    cursor: { ...delta.cursor },
    defaultFg: delta.default_fg ?? model.defaultFg,
    defaultBg: delta.default_bg ?? model.defaultBg,
    scrollbackRows: delta.scrollback_rows ?? model.scrollbackRows,
    rows,
  };
}
