import type { AcpmuxRow, ConversationLayout } from "../model";
import { hasRenderableMarkdown } from "./safeTail";

const rendered = new WeakMap<AcpmuxRow, boolean>();
function hasMessage(row: AcpmuxRow): boolean {
  const kept = rendered.get(row);
  if (kept !== undefined) return kept;
  const candidate =
    row.kind === "turnSummary" || row.kind === "assistant" || (row.kind === "user" && row.incoming?.kind === "message");
  if (!candidate) {
    rendered.set(row, false);
    return false;
  }
  const text = row.kind === "user" && row.incoming?.kind === "message" ? row.incoming.message.text : (row.text ?? "");
  const value = hasRenderableMarkdown(text, row.streaming === true);
  rendered.set(row, value);
  return value;
}

const latest = new WeakMap<ConversationLayout, number>();

/// Reuse layout's existing changed-suffix pass. Streaming content checks only changed row objects;
/// an unchanged empty tail keeps the known absence of a host, without searching history again.
export class MessagePlacement {
  private index: number;
  private search = -1;

  constructor(rows: readonly AcpmuxRow[], previous?: ConversationLayout) {
    const kept = previous && latest.get(previous);
    this.index = kept ?? -1;
    if (kept === undefined || this.index >= rows.length) {
      this.index = -1;
      this.search = previous ? rows.length - 1 : -1;
    }
  }

  visit(row: AcpmuxRow, index: number, previous?: AcpmuxRow): void {
    if (row === previous) return;
    if (hasMessage(row)) this.index = Math.max(this.index, index);
    else if (index === this.index) {
      // Only losing the selected message needs a backward fallback. Ordinary text deltas and
      // tool updates preserve its index, including when there has never been a message.
      this.index = -1;
      this.search = Math.max(this.search, index - 1);
    }
  }

  finish(rows: readonly AcpmuxRow[], layout: ConversationLayout): void {
    for (let index = this.search; index > this.index; index--) {
      if (hasMessage(rows[index]!)) {
        this.index = index;
        break;
      }
    }
    latest.set(layout, this.index);
  }
}

export function latestMessageRow(rows: readonly AcpmuxRow[], layout: ConversationLayout): string | undefined {
  return rows[latest.get(layout) ?? -1]?.id;
}
