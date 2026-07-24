// Terminal grid model + canvas painter for render-grid frames.
//
// The model applies full/delta frames exactly like the iOS mirror: a full
// frame replaces everything; a delta clears `cleared_rows`, repaints the rows
// present in `row_spans`, and refreshes the style table. Painting re-renders
// the character grid at the canvas's current pixel size, so text stays crisp
// at any viewer scale instead of bitmap-shrinking the host's pixels.

import type {
  GridCursor,
  GridStyle,
  GridRowSpan,
} from "./share-protocol";
import { normalizeRenderGridFrame } from "./share-protocol";

const DEFAULT_BG = "#0a0a0a";
const DEFAULT_FG = "#ededed";
const DEFAULT_CURSOR = "#ededed";

function hexColor(value: string | undefined, fallback: string): string {
  if (!value) return fallback;
  const v = value.trim();
  if (!v) return fallback;
  return v.startsWith("#") ? v : `#${v}`;
}

export class TerminalGridModel {
  cols = 0;
  rows = 0;
  cursor: GridCursor | null = null;
  background = DEFAULT_BG;
  foreground = DEFAULT_FG;
  cursorColor = DEFAULT_CURSOR;
  /** Monotonic generation, bumped on every applied frame. */
  generation = 0;
  private styles = new Map<number, GridStyle>();
  private spansByRow: GridRowSpan[][] = [];
  private seenFull = false;

  /** Returns false when the frame was unusable (bad format or delta-before-full). */
  apply(value: unknown): boolean {
    const frame = normalizeRenderGridFrame(value);
    if (!frame) return false;
    const full = frame.full !== false;
    if (!full && !this.seenFull) return false; // deltas need a base
    if (full) {
      this.seenFull = true;
      this.cols = frame.columns;
      this.rows = frame.rows;
      this.spansByRow = Array.from({ length: frame.rows }, () => []);
      this.styles.clear();
      this.background = hexColor(
        frame.terminal_theme?.background ?? frame.terminal_background,
        DEFAULT_BG,
      );
      this.foreground = hexColor(
        frame.terminal_theme?.foreground ?? frame.terminal_foreground,
        DEFAULT_FG,
      );
      this.cursorColor = hexColor(
        frame.terminal_cursor_color ?? frame.terminal_theme?.cursor,
        this.foreground,
      );
    } else if (frame.columns !== this.cols || frame.rows !== this.rows) {
      // Geometry changed without a full frame; wait for one.
      return false;
    }
    for (const style of frame.styles ?? []) this.styles.set(style.id, style);
    const clearedRows = new Set(frame.cleared_rows ?? []);
    if (!full) {
      for (const row of clearedRows) {
        if (row >= 0 && row < this.rows) this.spansByRow[row] = [];
      }
    }
    const touched = new Set<number>();
    for (const span of frame.row_spans) {
      if (span.row < 0 || span.row >= this.rows) continue;
      // A row's spans are replaced wholesale the first time this frame
      // touches it (full frames start from empty rows anyway).
      if (!full && !touched.has(span.row) && !clearedRows.has(span.row)) {
        this.spansByRow[span.row] = [];
      }
      touched.add(span.row);
      this.spansByRow[span.row]?.push(span);
    }
    for (const row of touched) {
      this.spansByRow[row]?.sort((a, b) => a.column - b.column);
    }
    // The producer's optional cursor is authoritative for every snapshot.
    // Leaving the previous value in place paints a ghost cursor after the
    // terminal hides it.
    this.cursor = frame.cursor ?? null;
    this.generation += 1;
    return true;
  }

  get ready(): boolean {
    return this.seenFull;
  }

  styleFor(id: number): GridStyle | undefined {
    return this.styles.get(id);
  }

  rowSpans(row: number): GridRowSpan[] {
    return this.spansByRow[row] ?? [];
  }
}

export interface PaintMetrics {
  cellW: number;
  cellH: number;
  offsetX: number;
  offsetY: number;
}

/**
 * Paint the grid into a canvas, letterboxed and centered. The canvas backing
 * store is resized to the element's CSS size x devicePixelRatio by the caller
 * (see ShareTerminalPane); this only draws.
 */
export function paintGrid(
  ctx: CanvasRenderingContext2D,
  model: TerminalGridModel,
  cssWidth: number,
  cssHeight: number,
  dpr: number,
): PaintMetrics | null {
  ctx.save();
  ctx.scale(dpr, dpr);
  ctx.fillStyle = model.background;
  ctx.fillRect(0, 0, cssWidth, cssHeight);
  if (!model.ready || model.cols === 0 || model.rows === 0) {
    ctx.restore();
    return null;
  }

  // Terminal cells are ~1:2 width:height. Fit cols x rows into the box.
  const cellH = Math.max(
    4,
    Math.min(cssHeight / model.rows, (cssWidth / model.cols) * 2),
  );
  const cellW = cellH / 2;
  const gridW = cellW * model.cols;
  const gridH = cellH * model.rows;
  const offsetX = Math.floor((cssWidth - gridW) / 2);
  const offsetY = Math.floor((cssHeight - gridH) / 2);
  const fontPx = cellH * 0.78;
  const baseFont = `${fontPx}px var(--font-geist-mono), ui-monospace, Menlo, monospace`;
  ctx.textBaseline = "middle";

  for (let row = 0; row < model.rows; row += 1) {
    const y = offsetY + row * cellH;
    for (const span of model.rowSpans(row)) {
      const style = model.styleFor(span.style_id);
      const x = offsetX + span.column * cellW;
      const chars = [...span.text];
      const cellWidth = span.cell_width ?? chars.length;
      let fg = hexColor(style?.foreground, model.foreground);
      let bg = style?.background ? hexColor(style.background, "") : "";
      if (style?.inverse) {
        const swappedBg = fg;
        fg = bg || model.background;
        bg = swappedBg;
      }
      if (bg) {
        ctx.fillStyle = bg;
        ctx.fillRect(x, y, cellWidth * cellW, cellH);
      }
      if (style?.invisible) continue;
      ctx.fillStyle = fg;
      ctx.globalAlpha = style?.faint ? 0.55 : 1;
      ctx.font = `${style?.italic ? "italic " : ""}${style?.bold ? "600 " : ""}${baseFont}`;
      // Draw per-cell so proportional fallbacks cannot drift off the grid.
      // Wide glyphs (CJK) occupy cell_width/chars cells each.
      const perChar = chars.length > 0 ? cellWidth / chars.length : 1;
      for (let i = 0; i < chars.length; i += 1) {
        const cx = x + i * perChar * cellW;
        ctx.fillText(chars[i] ?? "", cx, y + cellH / 2);
      }
      ctx.globalAlpha = 1;
      if (style?.underline || style?.strikethrough || style?.overline) {
        ctx.strokeStyle = fg;
        ctx.lineWidth = Math.max(1, cellH / 16);
        const spanW = cellWidth * cellW;
        const lineAt = (ly: number) => {
          ctx.beginPath();
          ctx.moveTo(x, ly);
          ctx.lineTo(x + spanW, ly);
          ctx.stroke();
        };
        if (style.underline) lineAt(y + cellH - ctx.lineWidth);
        if (style.strikethrough) lineAt(y + cellH / 2);
        if (style.overline) lineAt(y + ctx.lineWidth);
      }
    }
  }

  const cursor = model.cursor;
  if (cursor && cursor.visible !== false) {
    const x = offsetX + cursor.column * cellW;
    const y = offsetY + cursor.row * cellH;
    ctx.fillStyle = model.cursorColor;
    ctx.strokeStyle = model.cursorColor;
    switch (cursor.style ?? "block") {
      case "bar":
        ctx.fillRect(x, y, Math.max(1, cellW / 6), cellH);
        break;
      case "underline":
        ctx.fillRect(x, y + cellH - Math.max(1, cellH / 8), cellW, Math.max(1, cellH / 8));
        break;
      case "block_hollow":
        ctx.lineWidth = 1;
        ctx.strokeRect(x + 0.5, y + 0.5, cellW - 1, cellH - 1);
        break;
      default: {
        ctx.globalAlpha = 0.8;
        ctx.fillRect(x, y, cellW, cellH);
        ctx.globalAlpha = 1;
      }
    }
  }
  ctx.restore();
  return { cellW, cellH, offsetX, offsetY };
}
