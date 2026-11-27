/// The compact forms acpmux sends a page that asked for them in `initialize` (`initializeParams`),
/// read back into the frames the page handled before, so nothing past `receive` changes:
///
/// - `chunkDeltas` (acpmux server/chunk_deltas.rs): a streamed text chunk after the first is
///   `_acpmux/chunk {ref, seq, dt, text}`, about 100 B where the whole `_acpmux/event` is about
///   435 B. The last whole chunk event of the chat carries `chunkRef`; a chunk is that event with
///   this `seq`, `at` the previous frame's plus `dt`, and this text.
/// - `sessionChangedDelta` (acpmux server/session_patch.rs): after a chat's whole row
///   (`_acpmux/session_changed` with `rowSeq`), each change is `_acpmux/session_patch`, a merge patch
///   of the row held at `baseRowSeq`, under 2 KB where the row is 37-77 KB on a 10,000-message chat.
///
/// What the decoder cannot rebuild it reports as a gap and drops; the page then reads again what the
/// frame stood for (direct.ts `deltaGap`): the chat's records after its cursor (`_acpmux/events`,
/// after which acpmux sends the chat's next chunk whole) or the list from its cursor
/// (`_acpmux/watch`, after which it sends each chat's next row whole). One instance per socket:
/// refs and row numbers are a connection's own.

type Json = Record<string, unknown>;
type Frame = { method?: unknown; params?: unknown };

/// A frame the decoder could not rebuild. `sessionId` names the chat when the frame did.
export type DeltaGap = { gap: "chunk" | "row"; sessionId?: string; reason: string };

/// A chunk template: the last whole chunk event of one chat, less `chunkRef`.
type Template = { sessionId: string; params: Json; seq: number; at: number };

/// The page's host left frames out (AcpmuxPaneShedding.swift): its queue was full (any notice), the
/// pane was hidden (its chat's stream), or the page slept (other chats' rows).
const SHED_STREAM = new Set(["host_queue_full", "host_hidden"]);
const SHED_ROWS = new Set(["host_queue_full", "page_asleep"]);

export const MAX_ROWS = 512;
/// Refs already reported lost, kept to drop their later chunks quietly (the read covers them).
const MAX_LOST_REFS = 256;

const isObject = (value: unknown): value is Json =>
  typeof value === "object" && value !== null && !Array.isArray(value);
const isCount = (value: unknown): value is number =>
  typeof value === "number" && Number.isSafeInteger(value) && value >= 0;

/// Applies a `_acpmux/session_patch` `patch` to `held` without changing it (the page keys caches on
/// row objects): an object merges key by key, `null` removes the key (null and absent are the same
/// row field), `{"$splice": [from, keep, items]}` is `held[from..from + keep]` then `items`, anything
/// else replaces the value. Unchanged branches stay the same objects.
export function applyRowPatch(held: unknown, patch: unknown): unknown {
  if (!isObject(patch)) return patch;
  const splice = patch.$splice;
  if (Array.isArray(splice) && Object.keys(patch).length === 1) {
    const [from, keep, items] = splice as [number, number, unknown[]];
    const list = Array.isArray(held) ? held : [];
    return [...list.slice(from, from + keep), ...(Array.isArray(items) ? items : [])];
  }
  const out: Json = isObject(held) ? { ...held } : {};
  for (const [key, value] of Object.entries(patch)) {
    if (value === null) delete out[key];
    else out[key] = applyRowPatch(out[key], value);
  }
  return out;
}

export class ChatDeltas {
  private readonly templates = new Map<number, Template>();
  /// Each chat's current ref: a new whole chunk event replaces the chat's template.
  private readonly refOf = new Map<string, number>();
  /// Each chat's row as last rebuilt, by its row key (`qualifiedSessionId`, else `sessionId`).
  private readonly rows = new Map<string, { rowSeq: number; session: unknown }>();
  /// Rows whose patch did not apply: their patches are dropped until the whole row comes again,
  /// which the read the first gap asked for makes acpmux send.
  private readonly awaitingWhole = new Set<string>();
  /// Refs the page no longer rebuilds from: their later chunks are in the read the first gap (or the
  /// lag) asked for, which ends with acpmux sending the chat's next chunk whole.
  private readonly lostRefs = new Set<number>();

  /// The frame as the page handled it before the compact forms (`frame` itself when it is not one),
  /// a gap, or undefined for a frame to drop (a row's patch while its whole row is owed).
  decode<F extends Frame>(frame: F): F | DeltaGap | undefined {
    switch (frame.method) {
      case "_acpmux/event":
        return this.event(frame);
      case "_acpmux/chunk":
        return this.chunk(frame);
      case "_acpmux/session_changed":
        return this.rowChanged(frame);
      case "_acpmux/session_patch":
        return this.patch(frame);
      case "_acpmux/lagged":
        this.lagged(frame.params);
        return frame;
      default:
        return frame;
    }
  }

  private event<F extends Frame>(frame: F): F {
    const params = frame.params;
    if (!isObject(params) || !("chunkRef" in params)) return frame;
    const { chunkRef, ...event } = params;
    const sessionId = event.sessionId;
    const content = (((event.msg as Json | undefined)?.params as Json | undefined)?.update as Json | undefined)
      ?.content;
    if (
      isCount(chunkRef) &&
      typeof sessionId === "string" &&
      isCount(event.seq) &&
      typeof event.at === "number" &&
      isObject(content)
    ) {
      const before = this.refOf.get(sessionId);
      if (before !== undefined) this.templates.delete(before);
      this.refOf.set(sessionId, chunkRef);
      this.templates.set(chunkRef, { sessionId, params: event, seq: event.seq, at: event.at });
    }
    return { ...frame, params: event };
  }

  private chunk<F extends Frame>(frame: F): F | DeltaGap | undefined {
    const delta = isObject(frame.params) ? frame.params : {};
    const { ref, seq, dt, text, prev } = delta;
    const template = isCount(ref) ? this.templates.get(ref) : undefined;
    if (!template) {
      if (isCount(ref) && this.lostRefs.has(ref)) return undefined;
      if (isCount(ref)) this.loseRef(ref);
      return { gap: "chunk", reason: "unknown ref" };
    }
    const { sessionId } = template;
    if (!isCount(seq) || seq <= template.seq || typeof dt !== "number" || dt < 0 || typeof text !== "string") {
      // Out of order or malformed: what follows on this ref cannot be trusted either.
      this.forgetRef(ref as number);
      return { gap: "chunk", sessionId, reason: "seq out of order" };
    }
    const at = template.at + dt;
    template.seq = seq;
    template.at = at;
    const msg = template.params.msg as Json;
    const msgParams = msg.params as Json;
    const update = msgParams.update as Json;
    // `prev` (acpmux `Conn::stream_prev`) is this frame's own, never its template's.
    const { prev: _templatePrev, ...params } = template.params;
    const event = {
      ...params,
      seq,
      at,
      ...(isCount(prev) ? { prev } : {}),
      msg: { ...msg, params: { ...msgParams, update: { ...update, content: { ...(update.content as Json), text } } } },
    };
    return { method: "_acpmux/event", params: event } as unknown as F;
  }

  private rowChanged<F extends Frame>(frame: F): F {
    const params = frame.params;
    if (!isObject(params)) return frame;
    const key = rowKey(params);
    if (params.kind === "purged" && key) {
      this.rows.delete(key);
      this.awaitingWhole.delete(key);
    }
    if (!("rowSeq" in params)) return frame;
    const { rowSeq, ...changed } = params;
    if (key && isCount(rowSeq)) {
      this.holdRow(key, rowSeq, changed.session);
      this.awaitingWhole.delete(key);
    }
    return { ...frame, params: changed };
  }

  private patch<F extends Frame>(frame: F): F | DeltaGap | undefined {
    const params = isObject(frame.params) ? frame.params : {};
    const key = rowKey(params);
    const sessionId = typeof params.sessionId === "string" ? params.sessionId : undefined;
    if (!key) return { gap: "row", reason: "patch names no chat" };
    if (this.awaitingWhole.has(key)) return undefined;
    const held = this.rows.get(key);
    const { patch, rowSeq, baseRowSeq, ...notice } = params;
    if (!held || held.rowSeq !== baseRowSeq || !isCount(rowSeq) || !isObject(patch)) {
      this.rows.delete(key);
      this.awaitingWhole.add(key);
      return { gap: "row", sessionId, reason: held ? "base row not held" : "no row held" };
    }
    const session = applyRowPatch(held.session, patch);
    this.holdRow(key, rowSeq, session);
    return { method: "_acpmux/session_changed", params: { ...notice, session } } as unknown as F;
  }

  /// The host left frames out: a chunk's `dt` counts from a frame the page may not have had, and a
  /// row may have missed a patch. The page reads both again (direct.ts `resyncAfterLag`); until a
  /// whole frame comes, what follows is a gap.
  private lagged(params: unknown): void {
    const reason = isObject(params) ? params.reason : undefined;
    if (typeof reason !== "string") return;
    if (SHED_STREAM.has(reason)) {
      for (const ref of this.templates.keys()) this.loseRef(ref);
      this.templates.clear();
      this.refOf.clear();
    }
    if (SHED_ROWS.has(reason)) this.rows.clear();
  }

  /// acpmux keeps at most 256 chats' rows per connection (session_patch.rs `MAX_ROWS`) and sends a
  /// row it let go whole: twice that many here is never short of one it patches.
  private holdRow(key: string, rowSeq: number, session: unknown): void {
    this.rows.delete(key);
    this.rows.set(key, { rowSeq, session });
    if (this.rows.size > MAX_ROWS) this.rows.delete(this.rows.keys().next().value as string);
  }

  private loseRef(ref: number): void {
    if (this.lostRefs.size >= MAX_LOST_REFS) this.lostRefs.delete(this.lostRefs.values().next().value as number);
    this.lostRefs.add(ref);
  }

  private forgetRef(ref: number): void {
    const template = this.templates.get(ref);
    this.templates.delete(ref);
    this.loseRef(ref);
    if (template && this.refOf.get(template.sessionId) === ref) this.refOf.delete(template.sessionId);
  }
}

function rowKey(params: Json): string | undefined {
  const key = params.qualifiedSessionId ?? params.sessionId;
  if (typeof key === "string" && key) return key;
  const session = params.session;
  return isObject(session) && typeof session.sessionId === "string" ? session.sessionId : undefined;
}

export function isDeltaGap(value: unknown): value is DeltaGap {
  return isObject(value) && (value.gap === "chunk" || value.gap === "row");
}
