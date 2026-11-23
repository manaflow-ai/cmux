import { type AcpmuxRow, type ConversationLayout } from "../model";

/// The rows past each end of the mounted ones a live resize's frame still measures at the new width.
const LIVE_RESIZE_ROWS = 40;

/// The last layout estimate of a transcript: its rows, their layout, and the row width and chat it was made for.
/// `partial`: made in a live resize, so only the rows around the mounted ones are at that width.
export interface LastEstimate {
  rows: readonly AcpmuxRow[];
  layout: ConversationLayout;
  width: number;
  sessionId?: string;
  partial?: boolean;
}

/// What a new estimate takes from the last pass (layoutConversation's `last` and `resizing`). `last`: the last
/// estimate, or none when nothing of it may be kept (a new registry, chat or look). `placed`: the rows the last
/// placement mounted. `live`: the box's width changed again within LIVE_RESIZE_MS (a live resize).
/// - `kept`: the last estimate, when it is whole and for this width and chat: the rows it starts with keep
///   their heights.
/// - `resizing`: a live resize's frame at a new width measures only the rows around the mounted ones; the rest
///   keep the last layout's heights (O(rows in view), not O(rows)). A chat that window covers half of or more
///   is measured whole (a short chat costs less measured whole than placed again from row 0 over a partial
///   layout): that layout is not partial.
export function estimateFrom(
  last: LastEstimate | undefined,
  placed: { first: number; last: number } | undefined,
  live: boolean,
  rowWidth: number,
  sessionId: string | undefined,
  rowCount: number,
): {
  kept: LastEstimate | undefined;
  resizing:
    | {
        rows: readonly AcpmuxRow[];
        layout: ConversationLayout;
        from: number;
        to: number;
      }
    | undefined;
  partial: boolean;
} {
  if (!last || last.sessionId !== sessionId) return { kept: undefined, resizing: undefined, partial: false };
  if (last.width === rowWidth)
    return {
      kept: last.partial ? undefined : last,
      resizing: undefined,
      partial: false,
    };
  if (!live || !placed) return { kept: undefined, resizing: undefined, partial: false };
  const from = Math.max(0, placed.first - LIVE_RESIZE_ROWS);
  const to = placed.last + LIVE_RESIZE_ROWS;
  if ((to - from) * 2 >= rowCount) return { kept: undefined, resizing: undefined, partial: false };
  return {
    kept: undefined,
    resizing: { rows: last.rows, layout: last.layout, from, to },
    partial: true,
  };
}

/// The rows around the ones the last placement mounted, in `rows` (layoutConversation `near`): the same
/// rows by id, where `rows` kept their indices or took an older page before them. Undefined for another
/// chat or rows it cannot find there, so every row is measured.
export function nearView(
  placed:
    | {
        rows: readonly AcpmuxRow[];
        sessionId?: string;
        first: number;
        last: number;
      }
    | undefined,
  rows: readonly AcpmuxRow[],
  sessionId: string | undefined,
): { from: number; to: number } | undefined {
  if (!placed || placed.sessionId !== sessionId) return undefined;
  const id = placed.rows[placed.first]?.id;
  if (id === undefined) return undefined;
  const shift = rows[placed.first]?.id === id ? 0 : rows.length - placed.rows.length;
  if (rows[placed.first + shift]?.id !== id) return undefined;
  return {
    from: Math.max(0, placed.first + shift - LIVE_RESIZE_ROWS),
    to: placed.last + shift + LIVE_RESIZE_ROWS,
  };
}
