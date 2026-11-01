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
      ...(thread.fromHarness ? { fromHarness: thread.fromHarness } : {}),
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
  // A person's prompt (a guest's held or declined one, or any row with its author) is never a
  // notice, whatever its text looks like: laneReport.ts `laneNotice` says the same of its message.
  const queued = row.queuedMessage;
  if (queued?.person || queued?.held || queued?.declined) return undefined;
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
type InboxProjection = { rows: readonly AcpmuxRow[]; offsets: readonly number[] };
const inboxFlattenCache = new WeakMap<readonly AcpmuxRow[], InboxProjection>();
// Waiting rows already have an outer fold; delivered notices need their own. Search and display
// may use the same source array, so their flat and folded projections cannot share a cache.
const deliveredInboxCache = new WeakMap<readonly AcpmuxRow[], InboxProjection>();
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

const bodyKey = (sender: string, text: string): string => `${sender.trim().toLocaleLowerCase()}\u0000${text.trim()}`;

const inboxDeliveries = (thread: LaneNoticeThread): readonly { sender: string; text: string; promptId?: string }[] =>
  thread.messages?.length
    ? thread.messages
    : [
        {
          sender: thread.sender,
          text: thread.preview ?? "",
          ...(thread.promptIds?.length === 1 ? { promptId: thread.promptIds[0] } : {}),
        },
      ];

/** Parse one immutable notice once. These are display children, never turn/queue anchors. */
function inboxChildren(row: AcpmuxRow, notice: LaneNotice): readonly AcpmuxRow[] {
  const cached = inboxChildrenCache.get(row);
  if (cached) return cached;
  const children: AcpmuxRow[] = [];
  for (const thread of notice.threads ?? []) {
    for (const [index, delivery] of inboxDeliveries(thread).entries()) {
      children.push({
        id: `${row.id}:inbox:${thread.id}:${index}`,
        version: row.version,
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
                ...(thread.fromHarness ? { fromHarness: thread.fromHarness } : {}),
              },
            }
          : {}),
        incoming: {
          kind: "message",
          message: {
            name: delivery.sender,
            text: delivery.text,
            raw: delivery.text,
            threadId: thread.id,
            ...(delivery.promptId ? { msgId: delivery.promptId } : {}),
            ...(thread.fromSession && delivery.sender === thread.sender ? { sessionId: thread.fromSession } : {}),
            ...(thread.fromHarness && delivery.sender === thread.sender ? { harness: thread.fromHarness } : {}),
          },
        },
      });
    }
  }
  inboxChildrenCache.set(row, children);
  return children;
}

/// Preserve a queued wrapper's single action target on the first delivery that survives shared
/// inbox dedupe. The source prompt may duplicate an earlier direct message, so attaching it before
/// filtering could leave the retained rows without Send now/Dismiss.
function attachQueueSource(row: AcpmuxRow, children: readonly AcpmuxRow[]): readonly AcpmuxRow[] {
  if (!row.queuedMessage || children.length === 0) return children;
  const first = children[0]!;
  if (first.inboxQueue?.promptId === row.queuedMessage.promptId) return children;
  return [{ ...first, inboxQueue: row.queuedMessage }, ...children.slice(1)];
}

const projectedBatches = new WeakMap<AcpmuxRow, { children: readonly AcpmuxRow[]; row: AcpmuxRow }>();

function projectedBatch(row: AcpmuxRow, children: readonly AcpmuxRow[]): AcpmuxRow {
  const held = projectedBatches.get(row);
  if (held && held.children.length === children.length && held.children.every((child, i) => child === children[i]))
    return held.row;
  const threads = new Map<string, { id: string; sender: string }>();
  for (const child of children) {
    const message = child.incoming?.kind === "message" ? child.incoming.message : undefined;
    if (!message) continue;
    const id = message.threadId ?? child.id;
    threads.set(id, { id, sender: message.name });
  }
  const result: AcpmuxRow = {
    ...row,
    kind: LANE_NOTICE_BATCH,
    incoming: undefined,
    version: ++version,
    text: children.map((child) => child.text ?? "").join("\n"),
    joined: children.flatMap((child) => [child.id, ...(child.joined ?? [])]),
    inboxDeliveryBatch: true,
    laneNoticeBatch: { kind: "inbox", verdicts: {}, rows: children, threads: [...threads.values()] },
  };
  projectedBatches.set(row, { children, row: result });
  return result;
}

/** Display-only projection: every leaf shares one duplicate context, including leaves inside
 * batches. Source rows keep their turn and queue identity. A batch keeps its one quiet fold, but
 * its children are flat received rows; no harness wrapper is passed to the message renderer.
 */
export function flattenInboxRows(rows: readonly AcpmuxRow[]): readonly AcpmuxRow[] {
  return projectAllInboxRows(rows, false);
}

function projectAllInboxRows(rows: readonly AcpmuxRow[], foldNotices: boolean): readonly AcpmuxRow[] {
  const cache = foldNotices ? deliveredInboxCache : inboxFlattenCache;
  const cached = cache.get(rows);
  if (cached) return cached.rows;
  const deliveredIds = new Set<string>();
  const deliveredBodies = new Set<string>();
  let hasInbox = false;
  const collect = (members: readonly AcpmuxRow[]) => {
    for (const row of members) {
      if (row.laneNoticeBatch) {
        if (row.laneNoticeBatch.kind === "inbox") hasInbox = true;
        collect(row.laneNoticeBatch.rows);
        continue;
      }
      if (noticeOf(row)?.kind === "inbox" || row.inboxDelivery) {
        hasInbox = true;
        continue;
      }
      const message = row.incoming?.kind === "message" ? row.incoming.message : undefined;
      if (!message) continue;
      for (const id of [row.queuedMessage?.promptId, row.steerPromptId, message.msgId]) if (id) deliveredIds.add(id);
      deliveredBodies.add(bodyKey(message.name, message.text));
    }
  };
  collect(rows);
  if (!hasInbox) {
    cache.set(rows, { rows, offsets: rows.map((_, i) => i).concat(rows.length) });
    return rows;
  }
  const seenIds = new Set<string>();
  const seenBodies = new Set<string>();
  const keepDelivery = (child: AcpmuxRow): boolean => {
    const message = child.incoming?.kind === "message" ? child.incoming.message : undefined;
    if (!message) return false;
    const id = message.msgId;
    const body = bodyKey(message.name, message.text);
    if (id ? deliveredIds.has(id) || seenIds.has(id) : deliveredBodies.has(body) || seenBodies.has(body)) return false;
    if (id) seenIds.add(id);
    else seenBodies.add(body);
    return true;
  };
  const offsets: number[] = [];
  const project = (members: readonly AcpmuxRow[], insideInbox = false): AcpmuxRow[] => {
    const out: AcpmuxRow[] = [];
    for (const row of members) {
      if (!insideInbox) offsets.push(out.length);
      if (row.laneNoticeBatch?.kind === "inbox") {
        const children = project(row.laneNoticeBatch.rows, true);
        if (insideInbox) out.push(...children);
        else if (children.length) out.push(projectedBatch(row, children));
        continue;
      }
      const notice = noticeOf(row);
      if (notice?.kind === "inbox") {
        const children = attachQueueSource(row, inboxChildren(row, notice).filter(keepDelivery));
        if (foldNotices && !insideInbox && children.length > 1) out.push(projectedBatch(row, children));
        else out.push(...children);
      } else if (row.inboxDelivery) {
        if (keepDelivery(row)) out.push(row);
      } else {
        out.push(row);
      }
    }
    return out;
  };
  const out = project(rows);
  const result = out.length === rows.length && out.every((row, index) => row === rows[index]) ? rows : out;
  offsets.push(out.length);
  cache.set(rows, { rows: result, offsets });
  return result;
}

/** Reuse the display projection of the turn prefix that turnViewFrom already reused. Streaming
 * only changes assistant/tool rows: when the tail's incoming rows are the same immutable objects,
 * no delivery index is rebuilt and historical messages are neither visited nor reparsed. A new,
 * removed or updated message rebuilds the shared duplicate context once, across the whole list.
 * All reuse is keyed by source object identity, never row IDs shared by different chats.
 */
export function projectInboxRows(
  rows: readonly AcpmuxRow[],
  previous?: readonly AcpmuxRow[],
  reusedRows = 0,
): readonly AcpmuxRow[] {
  const cached = deliveredInboxCache.get(rows);
  if (cached) return cached.rows;
  const held = previous && deliveredInboxCache.get(previous);
  if (!previous || !held || reusedRows > Math.min(rows.length, previous.length)) return projectAllInboxRows(rows, true);
  const relevant = (row: AcpmuxRow) =>
    row.laneNoticeBatch !== undefined || row.incoming?.kind === "message" || row.incoming?.kind === "inbox";
  const oldMessages: { row: AcpmuxRow; index: number }[] = [];
  for (let i = reusedRows; i < previous.length; i += 1)
    if (relevant(previous[i]!)) oldMessages.push({ row: previous[i]!, index: i });
  let at = 0;
  for (let i = reusedRows; i < rows.length; i += 1) {
    if (!relevant(rows[i]!)) continue;
    if (oldMessages[at++]?.row !== rows[i]) return projectAllInboxRows(rows, true);
  }
  if (at !== oldMessages.length) return projectAllInboxRows(rows, true);
  const projected = held.rows.slice(0, held.offsets[reusedRows]);
  const offsets = held.offsets.slice(0, reusedRows);
  at = 0;
  for (let i = reusedRows; i < rows.length; i += 1) {
    offsets.push(projected.length);
    const row = rows[i]!;
    if (relevant(row)) {
      const oldIndex = oldMessages[at++]!.index;
      projected.push(...held.rows.slice(held.offsets[oldIndex], held.offsets[oldIndex + 1]));
    } else projected.push(row);
  }
  offsets.push(projected.length);
  deliveredInboxCache.set(rows, { rows: projected, offsets });
  return projected;
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
