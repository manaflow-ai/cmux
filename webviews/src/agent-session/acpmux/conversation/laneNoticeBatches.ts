import { LANE_NOTICE_BATCH, type AcpmuxRow } from "../model";
import { inboxText, type InboxNotice } from "./inboxNotice";
import { laneNotice, type LaneNotice, type LaneNoticeKind, type LaneNoticeThread } from "./laneReport";
type LaneNoticeVerdict = NonNullable<LaneNotice["verdict"]>;

export type LaneNoticeBatch = NonNullable<AcpmuxRow["laneNoticeBatch"]>;

const rowNoticeCache = new WeakMap<object, LaneNotice | undefined>();

const inboxLaneNotice = (notice: InboxNotice): LaneNotice => {
  const threads: LaneNoticeThread[] = notice.threads.map((thread) => {
    const messages = thread.messages?.map((message) => ({
      sender: message.from,
      text: message.text,
      ...(message.promptId ? { promptId: message.promptId } : {}),
    }));
    const sender = messages?.at(-1)?.sender ?? thread.from.at(-1) ?? "inbox";
    const preview = messages?.at(-1)?.text ?? thread.preview;
    return {
      id: thread.threadId,
      sender,
      ...(preview ? { preview } : {}),
      ...(messages?.length ? { messages } : {}),
      ...(thread.label ? { label: thread.label } : {}),
      ...(thread.promptIds.length ? { promptIds: thread.promptIds } : {}),
      ...(thread.fromSession ? { fromSession: thread.fromSession } : {}),
      count: thread.count,
    };
  });
  return {
    kind: "inbox",
    preview: [...new Set(threads.map((thread) => thread.sender).filter(Boolean))].join(", "),
    body: inboxText(notice),
    threads,
  };
};

/// Parse only the immutable incoming message object. laneNotice itself caches the presentation in a
/// WeakMap, so this remains constant-time when a transcript token updates around an unchanged row.
export const noticeOf = (row: AcpmuxRow): LaneNotice | undefined => {
  const incoming = row.incoming;
  if (incoming?.kind !== "message" && incoming?.kind !== "inbox") return undefined;
  const cacheKey = incoming.kind === "message" ? incoming.message : row;
  const cached = rowNoticeCache.get(cacheKey);
  if (cached !== undefined || rowNoticeCache.has(cacheKey)) return cached;
  if (incoming.kind === "inbox") {
    const parsed = inboxLaneNotice(incoming.notice);
    rowNoticeCache.set(cacheKey, parsed);
    return parsed;
  }
  const message = incoming.message;
  // Older inbox payloads strip their visible marker while retaining structured threads. Prefix a
  // private parser copy once; the original message object remains the renderer's source of truth.
  const parsed = laneNotice(
    message.noticeThreads && !message.text.trimStart().startsWith("[inbox]")
      ? { ...message, text: `[inbox] ${message.text}` }
      : message,
  );
  rowNoticeCache.set(cacheKey, parsed);
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
const inboxFlattenCache = new WeakMap<readonly AcpmuxRow[], readonly AcpmuxRow[]>();
const inboxChildrenCache = new WeakMap<AcpmuxRow, readonly AcpmuxRow[]>();

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

const bodyKey = (sender: string, text: string): string =>
  `${sender.trim().toLocaleLowerCase()}\u0000${text.trim()}`;

const inboxDeliveries = (thread: LaneNoticeThread): readonly { sender: string; text: string; promptId?: string }[] =>
  thread.messages?.length
    ? thread.messages
    : [{ sender: thread.sender, text: thread.preview ?? "" }];

/** Expand inbox notices into the message rows they announce, dropping a delivery already present
 * as a normal waiting message. This keeps the pending strip one flat run instead of a group inside
 * the waiting group, and makes the notice a quiet summary rather than a second copy of the message.
 */
export function flattenInboxRows(rows: readonly AcpmuxRow[]): readonly AcpmuxRow[] {
  const cached = inboxFlattenCache.get(rows);
  if (cached) return cached;
  if (rows.some((row) => row.laneNoticeBatch?.kind === "inbox" && row.inboxDeliveryBatch !== true)) {
    const expanded = rows.map((row) => {
      if (row.laneNoticeBatch?.kind !== "inbox" || row.inboxDeliveryBatch === true) return row;
      const children = flattenInboxRows(row.laneNoticeBatch.rows);
      return {
        ...row,
        text: children.map((child) => child.text ?? "").join("\n"),
        joined: children.map((child) => child.id),
        inboxDeliveryBatch: true as const,
        laneNoticeBatch: { ...row.laneNoticeBatch, rows: children },
      };
    });
    const result = expanded;
    inboxFlattenCache.set(rows, result);
    return result;
  }
  if (!rows.some((row) => noticeOf(row)?.kind === "inbox")) {
    inboxFlattenCache.set(rows, rows);
    return rows;
  }
  const deliveredIds = new Set<string>();
  const deliveredBodies = new Set<string>();
  for (const row of rows) {
    const notice = noticeOf(row);
    if (notice?.kind === "inbox") continue;
    const message = row.incoming?.kind === "message" ? row.incoming.message : undefined;
    if (!message) continue;
    const id = row.queuedMessage?.promptId ?? row.steerPromptId ?? message.msgId;
    if (id) deliveredIds.add(id);
    deliveredBodies.add(bodyKey(message.name, message.text));
  }
  const seenInboxIds = new Set<string>();
  const seenInboxBodies = new Set<string>();
  const out: AcpmuxRow[] = [];
  const appendChild = (child: AcpmuxRow) => {
    const message = child.incoming?.kind === "message" ? child.incoming.message : undefined;
    if (!message) return;
    const id = message.msgId;
    const body = bodyKey(message.name, message.text);
    const duplicate = id ? deliveredIds.has(id) || seenInboxIds.has(id) : deliveredBodies.has(body) || seenInboxBodies.has(body);
    if (duplicate) return;
    if (id) seenInboxIds.add(id);
    else seenInboxBodies.add(body);
    out.push(child);
  };
  for (const row of rows) {
    const notice = noticeOf(row);
    if (notice?.kind !== "inbox") {
      out.push(row);
      continue;
    }
    const cachedChildren = inboxChildrenCache.get(row);
    if (cachedChildren) {
      for (const child of cachedChildren) appendChild(child);
      continue;
    }
    const children: AcpmuxRow[] = [];
    for (const [threadIndex, thread] of (notice.threads ?? []).entries()) {
      for (const [messageIndex, delivery] of inboxDeliveries(thread).entries()) {
        const id = `${row.id}:inbox:${thread.id}:${messageIndex}`;
        const child: AcpmuxRow = {
          id,
          version: row.version + threadIndex + messageIndex,
          at: row.at,
          kind: "user",
          text: delivery.text,
          untyped: true,
          inboxDelivery: true,
          ...(row.steer ? { steer: row.steer } : {}),
          ...(!thread.messages?.length
            ? {
                inboxThread: {
                  threadId: thread.id,
                  ...(thread.label ? { label: thread.label } : {}),
                  sender: delivery.sender,
                  preview: delivery.text,
                  count: thread.count ?? 1,
                  promptIds: thread.promptIds ?? [],
                  ...(thread.fromSession ? { fromSession: thread.fromSession } : {}),
                },
              }
            : {}),
          incoming: {
            kind: "message",
            message: {
              name: delivery.sender,
              text: delivery.text,
              raw: delivery.text,
              ...(delivery.promptId ? { msgId: delivery.promptId } : {}),
            },
          },
        };
        children.push(child);
        appendChild(child);
      }
    }
    inboxChildrenCache.set(row, children);
  }
  const result = out.length === rows.length && out.every((row, index) => row === rows[index]) ? rows : out;
  inboxFlattenCache.set(rows, result);
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
