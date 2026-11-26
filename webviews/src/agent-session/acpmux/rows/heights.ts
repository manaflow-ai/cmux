// The native v2 client remembers CSS border boxes at the width at which the page drew them.
// Only a settled source row has a book id and revision that can name it across windows.
import { callNative } from "../callNative";
import { nextDrawnRow, prevDrawnRow, rowEdge, type AcpmuxRow } from "../model";
import { rowOpenState } from "../conversation/rowOpenState";
import { bookEdition, bookRevision } from "./bookRevision";

export type RowHeightKey = { id: number; rev: number; edition: number; width: number; signature: string };
export type MeasuredRow = RowHeightKey & { height: number };
const BATCH = 256;

const identities = new WeakMap<object, number>();
let next = 0;
/// The native client handle lives for this document. A different renderer or display settings
/// object names a fresh layout within it, even when the chat and its column width are the same.
export function layoutIdentity(value: object): number {
  let id = identities.get(value);
  if (id === undefined) {
    id = ++next;
    identities.set(value, id);
  }
  return id;
}

export function heightKey(
  rows: readonly AcpmuxRow[],
  index: number,
  sessionId: string | undefined,
  layout: string,
  width: number,
): RowHeightKey | undefined {
  const row = rows[index];
  if (!row || row.streaming || row.steer === "waiting" || (row.kind !== "user" && row.kind !== "assistant")) return;
  const match = /^row-(\d+)$/.exec(row.id);
  const rev = bookRevision(row);
  const edition = bookEdition(row);
  if (!match || rev === undefined || edition === undefined) return;
  const edge = rowEdge(row, nextDrawnRow(rows, index), prevDrawnRow(rows, index));
  return {
    id: Number(match[1]),
    rev,
    edition,
    width: Math.round(width * 64),
    signature: JSON.stringify([layout, row.kind, row.at, row.text?.length, edge, rowOpenState(sessionId, row)]),
  };
}

export function writeHeights(sid: string, entries: readonly MeasuredRow[]): void {
  for (let start = 0; start < entries.length; start += BATCH)
    void callNative("chat.rows.heights.write", {
      sid,
      entries: entries.slice(start, start + BATCH),
    }).catch(() => {});
}

/// The Rust cache echoes the key with every hit. Native errors and evictions leave the normal
/// estimate in place until the browser delivers that row's border box.
export async function readHeights(sid: string, rows: readonly RowHeightKey[]): Promise<MeasuredRow[]> {
  const batches: Promise<MeasuredRow[]>[] = [];
  for (let start = 0; start < rows.length; start += BATCH) {
    batches.push(
      callNative<{ rows: (RowHeightKey & { height: number | null })[] }>("chat.rows.heights.read", {
        sid,
        rows: rows.slice(start, start + BATCH),
      })
        .then((reply) =>
          reply.rows.filter(
            (entry): entry is MeasuredRow =>
              Number.isFinite(entry.height) && entry.height !== null && entry.height >= 0,
          ),
        )
        .catch(() => []),
    );
  }
  return (await Promise.all(batches)).flat();
}
