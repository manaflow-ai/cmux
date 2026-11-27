import type { AcpmuxRow } from "../model";

/// Copy source text rather than rendered Markdown, including rows outside the virtual viewport.
export function transcriptCopyText(row: AcpmuxRow): string {
  const parts: string[] = [];
  if (row.text?.trim()) parts.push(row.text.trim());
  if (row.shell) {
    if (row.shell.command.trim()) parts.push(`$ ${row.shell.command.trim()}`);
    if (row.shell.output.trim()) parts.push(row.shell.output.trim());
    if (row.shell.error?.trim()) parts.push(row.shell.error.trim());
  }
  for (const item of row.items ?? []) {
    if (item.text.trim()) parts.push(item.text.trim());
    if (item.tool?.output?.trim()) parts.push(item.tool.output.trim());
  }
  return parts.join("\n").trim();
}

/// Whether `transcriptCopyText(row)` would be non-empty, without trimming or joining the row's
/// text. Each visible row asks this on every scroll frame, and a tool row's output can be large.
export function hasTranscriptCopyText(row: AcpmuxRow): boolean {
  if (hasText(row.text)) return true;
  if (row.shell) {
    if (hasText(row.shell.command) || hasText(row.shell.output) || hasText(row.shell.error)) return true;
  }
  for (const item of row.items ?? []) {
    if (hasText(item.text) || hasText(item.tool?.output)) return true;
  }
  return false;
}

const NON_BLANK = /\S/;
const hasText = (text: string | undefined | null) => !!text && NON_BLANK.test(text);

/// turnView gives the footer its answer's text for its Copy button. A selected range that
/// includes that answer has already copied it; a footer selected on its own still copies it.
/// Track the answer within its turn instead of deduplicating text across unrelated messages.
export function transcriptRangeText(rows: readonly AcpmuxRow[], rowIds: readonly string[]): string {
  const selected = new Set(rowIds);
  const parts: string[] = [];
  let answer: AcpmuxRow | undefined;
  for (const row of rows) {
    if (row.kind === "user") answer = undefined;
    if (row.kind === "assistant") answer = row;
    const repeatsAnswer = row.kind === "turnSummary" && answer && selected.has(answer.id) && row.text === answer.text;
    if (selected.has(row.id) && !repeatsAnswer) {
      const text = transcriptCopyText(row);
      if (text) parts.push(text);
    }
    if (row.kind === "turnSummary") answer = undefined;
  }
  return parts.join("\n\n");
}
