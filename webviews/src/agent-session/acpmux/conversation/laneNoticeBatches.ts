import { LANE_NOTICE_BATCH, type AcpmuxRow } from "../model";
import { laneNotice, type LaneNotice, type LaneNoticeKind } from "./laneReport";
type LaneNoticeVerdict = NonNullable<LaneNotice["verdict"]>;

export type LaneNoticeBatch = NonNullable<AcpmuxRow["laneNoticeBatch"]>;

const rowNoticeCache = new WeakMap<object, LaneNotice | undefined>();

/// Parse only the immutable incoming message object. laneNotice itself caches the presentation in a
/// WeakMap, so this remains constant-time when a transcript token updates around an unchanged row.
export const noticeOf = (row: AcpmuxRow): LaneNotice | undefined => {
  const incoming = row.incoming;
  if (incoming?.kind !== "message") return undefined;
  const message = incoming.message;
  const cached = rowNoticeCache.get(message);
  if (cached !== undefined || rowNoticeCache.has(message)) return cached;
  // Older inbox payloads strip their visible marker while retaining structured threads. Prefix a
  // private parser copy once; the original message object remains the renderer's source of truth.
  const parsed = laneNotice(
    message.noticeThreads && !message.text.trimStart().startsWith("[inbox]")
      ? { ...message, text: `[inbox] ${message.text}` }
      : message,
  );
  rowNoticeCache.set(message, parsed);
  return parsed;
};

const batchOf = (row: AcpmuxRow): LaneNoticeBatch | undefined => row.laneNoticeBatch;
type DeliveryPhase = "waiting" | "delivered";
const deliveryPhase = (row: AcpmuxRow): DeliveryPhase =>
  row.kind === "queuedMessage" || row.steer === "waiting" ? "waiting" : "delivered";
const phaseOf = (row: AcpmuxRow): DeliveryPhase => {
  const batch = batchOf(row);
  return batch ? deliveryPhase(batch.rows[0]!) : deliveryPhase(row);
};

let version = 0;
const extensionCache = new WeakMap<AcpmuxRow, WeakMap<AcpmuxRow, AcpmuxRow>>();
const listCache = new WeakMap<readonly AcpmuxRow[], readonly AcpmuxRow[]>();

function counts(rows: readonly AcpmuxRow[]): Partial<Record<LaneNoticeVerdict, number>> {
  const result: Partial<Record<LaneNoticeVerdict, number>> = {};
  for (const row of rows) {
    const verdict = noticeOf(row)?.verdict;
    if (verdict) result[verdict] = (result[verdict] ?? 0) + 1;
  }
  return result;
}

function threadList(rows: readonly AcpmuxRow[]): readonly { id: string; sender: string }[] {
  const seen = new Set<string>();
  const result: { id: string; sender: string }[] = [];
  for (const row of rows) {
    for (const thread of noticeOf(row)?.threads ?? []) {
      if (!thread.id || seen.has(thread.id)) continue;
      seen.add(thread.id);
      result.push(thread);
    }
  }
  return result;
}

function makeBatch(rows: readonly AcpmuxRow[], kind: LaneNoticeKind): AcpmuxRow {
  const first = rows[0]!;
  return {
    id: `lane-notices:${first.id}`,
    version: ++version,
    at: first.at,
    kind: LANE_NOTICE_BATCH,
    text: rows.map((row) => noticeOf(row)?.preview ?? row.text ?? "").join("\n"),
    untyped: true,
    joined: rows.map((row) => row.id),
    laneNoticeBatch: { kind, rows, verdicts: counts(rows), threads: threadList(rows) },
  };
}

function extendBatch(previous: AcpmuxRow, next: AcpmuxRow): AcpmuxRow {
  let byNext = extensionCache.get(previous);
  if (!byNext) {
    byNext = new WeakMap<AcpmuxRow, AcpmuxRow>();
    extensionCache.set(previous, byNext);
  }
  const cached = byNext.get(next);
  if (cached) return cached;
  const current = batchOf(previous);
  const result = current
    ? makeBatch([...current.rows, next], current.kind)
    : makeBatch([previous, next], noticeOf(next)!.kind);
  byNext.set(next, result);
  return result;
}

/// Add a row to a transcript result. A singleton stays a normal row; the second consecutive
/// notice creates the fold, and later notices extend that fold without rescanning the transcript.
export function appendLaneNotice(out: AcpmuxRow[], row: AcpmuxRow): void {
  const notice = noticeOf(row);
  if (!notice || out.length === 0) {
    out.push(row);
    return;
  }
  const previous = out.at(-1)!;
  const previousNotice = noticeOf(previous);
  const previousBatch = batchOf(previous);
  const previousKind = previousBatch?.kind ?? previousNotice?.kind;
  if (previousKind !== notice.kind || phaseOf(previous) !== deliveryPhase(row)) {
    out.push(row);
    return;
  }
  out[out.length - 1] = extendBatch(previous, row);
}

/// Batch after an arrival, not from the per-token render path. An unchanged array gets the exact
/// same result identity, preserving virtualization and avoiding O(rows) work on every token.
export function batchLaneNotices(rows: readonly AcpmuxRow[]): readonly AcpmuxRow[] {
  const cached = listCache.get(rows);
  if (cached) return cached;
  const out: AcpmuxRow[] = [];
  for (const row of rows) appendLaneNotice(out, row);
  const result = out.length === rows.length && out.every((row, index) => row === rows[index]) ? rows : out;
  listCache.set(rows, result);
  return result;
}
