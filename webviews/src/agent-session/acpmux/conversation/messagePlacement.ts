import type { AcpmuxRow, ConversationLayout } from "../model";
import { isVisiblyEmptyText } from "./visibleMessage";
// Candidate selection never parses a growing reply. Only the mounted renderer can confirm
// that its displayed prefix actually provides a host (including custom registry renderers).
function hasMessage(row: AcpmuxRow): boolean {
  if (row.kind === "turnSummary" || row.kind === "assistant") return !isVisiblyEmptyText(row.text);
  return row.kind === "user" && row.incoming?.kind === "message" && row.incoming.message.text.length > 0;
}

const latest = new WeakMap<ConversationLayout, number>();

/// Reuse layout's existing changed-suffix pass. Candidate checks only changed row objects;
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
  return latestMessage(rows, layout)?.id;
}

export function latestMessage(rows: readonly AcpmuxRow[], layout: ConversationLayout): AcpmuxRow | undefined {
  return rows[latestMessageIndex(layout)];
}

/// The latest message's index in the rows `layout` placed, or -1 when there is none.
export function latestMessageIndex(layout: ConversationLayout): number {
  return latest.get(layout) ?? -1;
}
