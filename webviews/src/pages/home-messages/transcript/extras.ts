// Rows the page adds to a transcript beside the messages' own (rows.ts): an agents row under the
// Chief message it belongs to (its pills), and rows after the newest message (the Chief's status
// line, the room a toast takes). They lay out in the same window as every other row, so they scroll,
// measure and move with the messages; one pass over the rows places them.
import type { ReactNode } from "react";
import type { TranscriptRow } from "./rows";

/** One added row: its own key, its height before it is measured, and what it draws. */
export interface TranscriptExtra {
  key: string;
  estimate: number;
  node: ReactNode;
}

export interface TranscriptExtras {
  /** By message id: rows after that message's own rows (its bubbles, labels and receipt). */
  after?: ReadonlyMap<string, readonly TranscriptExtra[]>;
  /** Rows after everything else (the typing row included). */
  tail?: readonly TranscriptExtra[];
}

export type ShownRow = TranscriptRow | (TranscriptExtra & { kind: "extra" });

/** The message a row belongs to, when it is one of a message's own rows. */
function ownerOf(row: TranscriptRow): string | undefined {
  switch (row.kind) {
    case "bubble":
      return row.message.id;
    case "label":
    case "receipt":
    case "unsent": {
      const at = row.key.indexOf(":");
      return at < 0 ? undefined : row.key.slice(at + 1);
    }
    default:
      return undefined;
  }
}

/** `rows` with `extras` placed: O(rows), and `rows` itself when there is nothing to add. */
export function withExtras(rows: readonly TranscriptRow[], extras: TranscriptExtras | undefined): readonly ShownRow[] {
  const after = extras?.after;
  const tail = extras?.tail ?? [];
  if (!after?.size && !tail.length) return rows;
  const out: ShownRow[] = [];
  let current: string | undefined;
  const flush = () => {
    const added = current !== undefined ? after?.get(current) : undefined;
    if (added) for (const extra of added) out.push({ ...extra, kind: "extra" });
    current = undefined;
  };
  for (const row of rows) {
    const owner = ownerOf(row);
    if (owner === undefined || owner !== current) flush();
    if (owner !== undefined) current = owner;
    out.push(row);
  }
  flush();
  for (const extra of tail) out.push({ ...extra, kind: "extra" });
  return out;
}
