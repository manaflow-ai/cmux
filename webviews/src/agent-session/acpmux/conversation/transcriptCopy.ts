import type { AcpmuxRow } from "../model";

/// Copy source text rather than rendered Markdown, including rows outside the virtual viewport.
export function transcriptCopyText(row: AcpmuxRow): string {
  const parts: string[] = [];
  // Another session's message copies as its words, never the envelope around them.
  const text = row.message ? row.message.body : row.text;
  if (text?.trim()) parts.push(text.trim());
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
