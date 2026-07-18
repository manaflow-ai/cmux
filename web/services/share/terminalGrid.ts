import type { TerminalGridFrame, TerminalRowSpan, TerminalStyle } from "./protocol";

export type RenderedTerminalGrid = {
  readonly surfaceId: string;
  readonly stateSeq: number;
  readonly columns: number;
  readonly rows: number;
  readonly rowSpans: readonly (readonly TerminalRowSpan[])[];
  readonly styles: ReadonlyMap<number, TerminalStyle>;
  readonly background: string;
  readonly foreground: string;
  readonly cursor: TerminalGridFrame["cursor"];
};

export function applyTerminalGridFrame(
  previous: RenderedTerminalGrid | undefined,
  frame: TerminalGridFrame,
): RenderedTerminalGrid | null {
  if (!frame.full && (
    !previous ||
    previous.surfaceId !== frame.surface_id ||
    previous.columns !== frame.columns ||
    previous.rows !== frame.rows ||
    frame.state_seq <= previous.stateSeq
  )) return null;
  if (frame.full && previous && frame.state_seq < previous.stateSeq) return previous;

  const rows: TerminalRowSpan[][] = frame.full
    ? Array.from({ length: frame.rows }, () => [])
    : previous!.rowSpans.map((row) => [...row]);
  for (const row of frame.cleared_rows) {
    if (Number.isSafeInteger(row) && row >= 0 && row < rows.length) rows[row] = [];
  }
  const spansByRow = new Map<number, TerminalRowSpan[]>();
  for (const span of frame.row_spans) {
    if (
      !Number.isSafeInteger(span.row) || span.row < 0 || span.row >= frame.rows ||
      !Number.isSafeInteger(span.column) || span.column < 0 || span.column >= frame.columns ||
      typeof span.text !== "string"
    ) continue;
    const row = spansByRow.get(span.row) ?? [];
    row.push(span);
    spansByRow.set(span.row, row);
  }
  for (const [row, spans] of spansByRow) rows[row] = spans.sort((left, right) => left.column - right.column);

  const styles = frame.full
    ? new Map(frame.styles.map((style) => [style.id, style]))
    : new Map([...(previous?.styles ?? []), ...frame.styles.map((style) => [style.id, style] as const)]);
  return {
    surfaceId: frame.surface_id,
    stateSeq: frame.state_seq,
    columns: frame.columns,
    rows: frame.rows,
    rowSpans: rows,
    styles,
    background: normalizeColor(frame.terminal_background) ?? previous?.background ?? "#101114",
    foreground: normalizeColor(frame.terminal_foreground) ?? previous?.foreground ?? "#f3f4f6",
    cursor: frame.cursor,
  };
}

export function normalizeColor(value: string | undefined): string | null {
  if (!value) return null;
  const prefixed = value.startsWith("#") ? value : `#${value}`;
  return /^#[0-9A-Fa-f]{6}(?:[0-9A-Fa-f]{2})?$/.test(prefixed) ? prefixed : null;
}
