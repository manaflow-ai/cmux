// A reply's Markdown table as the clipboard carries it (TableBlock.tsx Copy): the Markdown for a
// chat or an editor, TSV and an HTML table so Sheets, Numbers, Notes and Docs paste real cells.
import type { Align } from "./Markdown";
import { inlinePlainText } from "./messageMenu";

export type Table = { align: Align[]; header: string[]; rows: string[][] };

/// The table's columns: its header's, or a longer row's.
function columnCount(table: Table): number {
  return Math.max(table.header.length, ...table.rows.map((row) => row.length));
}

/// Whether the header has words; an all-blank one draws as no header row and pastes as none.
export function hasHeader(table: Table): boolean {
  return table.header.some((cell) => cell.trim());
}

function pastedRows(table: Table): string[][] {
  return hasHeader(table) ? [table.header, ...table.rows] : table.rows;
}

function padded(cells: string[], count: number): string[] {
  return Array.from({ length: count }, (_, i) => cells[i] ?? "");
}

/// A cell's words without its inline syntax, on one line.
function cellText(cell: string): string {
  return inlinePlainText(cell).replace(/\s+/g, " ").trim();
}

export function tableMarkdown(table: Table): string {
  const count = columnCount(table);
  // A pipe in a cell is written escaped again, or the copied table would grow a column.
  const line = (cells: string[]) =>
    `| ${padded(cells, count)
      .map((cell) => cell.replace(/\|/g, "\\|"))
      .join(" | ")} |`;
  const rule = padded([], count).map((_, i) => {
    const align = table.align[i];
    return align === "center" ? ":---:" : align === "right" ? "---:" : align === "left" ? ":---" : "---";
  });
  return [line(table.header), `| ${rule.join(" | ")} |`, ...table.rows.map(line)].join("\n");
}

export function tableTsv(table: Table): string {
  const count = columnCount(table);
  return pastedRows(table)
    .map((cells) => padded(cells, count).map(cellText).join("\t"))
    .join("\n");
}

const ESCAPES: Record<string, string> = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" };
const escape = (text: string) => text.replace(/[&<>"]/g, (c) => ESCAPES[c]!);

export function tableHtml(table: Table): string {
  const count = columnCount(table);
  const cells = (row: string[], tag: "th" | "td") =>
    padded(row, count)
      .map((cell, i) => {
        const align = table.align[i];
        return `<${tag}${align ? ` style="text-align:${align}"` : ""}>${escape(cellText(cell))}</${tag}>`;
      })
      .join("");
  const body = table.rows.map((row) => `<tr>${cells(row, "td")}</tr>`).join("");
  const head = hasHeader(table) ? `<thead><tr>${cells(table.header, "th")}</tr></thead>` : "";
  return `<table>${head}<tbody>${body}</tbody></table>`;
}

/// The clipboard's entry for a table: Markdown as its text, the HTML table, and TSV where the
/// clipboard takes that type.
export function tableClipboard(table: Table): Record<string, string> {
  const entry: Record<string, string> = { "text/plain": tableMarkdown(table), "text/html": tableHtml(table) };
  const supports = (globalThis.ClipboardItem as { supports?: (type: string) => boolean } | undefined)?.supports;
  if (supports?.("text/tab-separated-values")) entry["text/tab-separated-values"] = tableTsv(table);
  return entry;
}

/// Puts the table on the clipboard in every format; where the page may only copy text, its Markdown.
export async function copyTable(table: Table, copyText: (text: string) => Promise<boolean>): Promise<boolean> {
  try {
    const entry = tableClipboard(table);
    await navigator.clipboard.write([
      new ClipboardItem(
        Object.fromEntries(Object.entries(entry).map(([type, text]) => [type, new Blob([text], { type })])),
      ),
    ]);
    return true;
  } catch {
    return copyText(tableMarkdown(table));
  }
}
