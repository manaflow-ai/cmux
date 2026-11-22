/**
 * The files tree's "+N -N" counts, green additions and red deletions.
 *
 * `renderRowDecoration` (@pierre/trees 1.0.0-beta.4) renders one plain text
 * span or one icon per row: a text decoration has a single color, and the
 * rows carry no attribute the counts could be styled by. The icon path takes
 * any symbol of the tree's `icons.spriteSheet`, so each distinct count pair is
 * one `<symbol>` that draws both numbers as SVG text in their own colors. The
 * text inherits the row's font, and the colors are the tree's status
 * variables, so the counts follow the theme like the rest of the tree.
 */
export type DiffFileStats = { added: number; deleted: number };

export type FileTreeStatsDecoration = {
  icon: { name: string; width: number; height: number; viewBox: string };
  title: string;
};

/** The counts' text size: a point under the file name, as in the classic list. */
export const FILE_TREE_STATS_FONT_SIZE = 12;
const SYMBOL_HEIGHT = 16;
/** The 12 px text's alphabetic baseline in the 16 px symbol, a little above the row's middle like the classic counts. */
const BASELINE = 11;

/** The parts a row shows: only the nonzero counts, "+N" before "-N". */
export function diffStatParts(stats: DiffFileStats | undefined): { added?: string; deleted?: string } | null {
  if (stats == null || (stats.added <= 0 && stats.deleted <= 0)) {
    return null;
  }
  return {
    added: stats.added > 0 ? `+${stats.added}` : undefined,
    deleted: stats.deleted > 0 ? `-${stats.deleted}` : undefined,
  };
}

export function diffStatSymbolId(stats: DiffFileStats): string {
  return `cmux-diff-stat-${Math.max(0, stats.added)}-${Math.max(0, stats.deleted)}`;
}

export type MeasureText = (text: string) => number;

/** Text width at the row font, from a canvas when there is one. */
export function createTextMeasure(fontFamily: string): MeasureText {
  let context: CanvasRenderingContext2D | null = null;
  try {
    context = typeof document === "undefined" ? null : document.createElement("canvas").getContext("2d");
  } catch {
    context = null;
  }
  if (context == null) {
    // No canvas (tests): a tabular digit is about 0.6 em.
    return (text) => text.length * FILE_TREE_STATS_FONT_SIZE * 0.6;
  }
  context.font = `${FILE_TREE_STATS_FONT_SIZE}px ${fontFamily}`;
  const canvas = context;
  return (text) => canvas.measureText(text).width;
}

function symbolWidth(stats: DiffFileStats, measure: MeasureText): number {
  const parts = diffStatParts(stats);
  const text = [parts?.added, parts?.deleted].filter(Boolean).join(" ");
  // Slack for tabular digits, which the canvas does not measure.
  return Math.ceil(measure(text) * 1.04) + 2;
}

/** The row decoration for a file's counts, or null when it has none. */
export function fileTreeStatsDecoration(
  stats: DiffFileStats | undefined,
  titles: { additions: string; deletions: string },
  measure: MeasureText,
): FileTreeStatsDecoration | null {
  const parts = diffStatParts(stats);
  if (stats == null || parts == null) {
    return null;
  }
  const width = symbolWidth(stats, measure);
  const title = [
    parts.added ? `${titles.additions} ${stats.added}` : null,
    parts.deleted ? `${titles.deletions} ${stats.deleted}` : null,
  ]
    .filter(Boolean)
    .join(", ");
  return {
    icon: { name: diffStatSymbolId(stats), width, height: SYMBOL_HEIGHT, viewBox: `0 0 ${width} ${SYMBOL_HEIGHT}` },
    title,
  };
}

function escapeXML(text: string): string {
  return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

/**
 * One `<symbol>` per distinct count pair, for the tree's `icons.spriteSheet`,
 * after any `extraSymbols` the sheet also carries.
 */
export function diffStatSpriteSheet(
  statsList: Iterable<DiffFileStats>,
  measure: MeasureText,
  extraSymbols = "",
): string {
  const symbols = new Map<string, string>();
  for (const stats of statsList) {
    const parts = diffStatParts(stats);
    const id = diffStatSymbolId(stats);
    if (parts == null || symbols.has(id)) {
      continue;
    }
    const width = symbolWidth(stats, measure);
    const spans = [
      parts.added ? `<tspan style="fill: var(--trees-status-added)">${escapeXML(parts.added)}</tspan>` : "",
      parts.added && parts.deleted ? " " : "",
      parts.deleted ? `<tspan style="fill: var(--trees-status-deleted)">${escapeXML(parts.deleted)}</tspan>` : "",
    ].join("");
    symbols.set(
      id,
      `<symbol id="${id}" viewBox="0 0 ${width} ${SYMBOL_HEIGHT}">` +
        `<text x="${width}" y="${BASELINE}" text-anchor="end" xml:space="preserve" ` +
        `style="font-family: inherit; font-size: ${FILE_TREE_STATS_FONT_SIZE}px; font-variant-numeric: tabular-nums">${spans}</text>` +
        `</symbol>`,
    );
  }
  return `<svg xmlns="http://www.w3.org/2000/svg" aria-hidden="true" width="0" height="0" style="position:absolute">${extraSymbols}${Array.from(symbols.values()).join("")}</svg>`;
}
