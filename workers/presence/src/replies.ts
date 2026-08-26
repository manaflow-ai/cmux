// Phone reply inbox — the server half of inline notification replies.
//
// A locked iPhone cannot be trusted to hold a live P2P session to the Mac: the
// reply action wakes the app for seconds, and every transport dial is at the
// mercy of iOS background scheduling. So the phone hands the reply to this
// service with ONE authenticated HTTPS POST, the reply parks durably in the
// account's connectivity Durable Object, and the Mac — which already holds the
// account connectivity WebSocket — is nudged with the existing
// `connectivity.invalidate` frame (revision 1, a value every deployed client
// already treats as a stale-revision no-op for routes) and fetches the inbox
// over HTTPS. Delivery to the terminal happens on the Mac, on wall power, on
// a real network.
//
// This module is the pure half (validation, caps, storage ops against a
// minimal storage interface) so it unit-tests without the Workers runtime,
// mirroring core.ts/syncStorage.ts.

/** One parked reply. Stored shape and wire shape are identical. */
export interface StoredPhoneReply {
  replyId: string;
  macDeviceId: string;
  workspaceId: string;
  surfaceId: string;
  notificationId: string;
  text: string;
  createdAtMs: number;
  expiresAtMs: number;
}

/** Replies target a live agent prompt; one that sat undelivered this long is
 * stale enough that typing it into the terminal would surprise the user. The
 * phone schedules its local "Reply not sent" notice past its own send
 * lifetime, so an expiry here is not silent on the phone side. */
export const PHONE_REPLY_TTL_MS = 15 * 60 * 1000;
/** Pending replies per account. Replies are human-typed and rare; a queue
 * this deep means the Mac has been away for a while, and older entries are
 * closer to their TTL anyway. Oldest is evicted first past the cap. */
export const MAX_PENDING_PHONE_REPLIES = 20;
export const MAX_PHONE_REPLY_TEXT_CHARS = 8_192;
export const MAX_PHONE_REPLY_ID_CHARS = 64;
export const MAX_PHONE_REPLY_TARGET_ID_CHARS = 128;
/** Bound for the enqueue request body read. */
export const MAX_PHONE_REPLY_BODY_BYTES = 64 * 1024;
/** The revision broadcast as the inbox nudge. Deliberately the LOWEST valid
 * revision: every deployed client passes it to its route reconcile, which
 * treats an old revision as already-satisfied, so the frame costs old clients
 * nothing — while a reply-aware Mac sweeps the inbox on EVERY frame arrival,
 * regardless of revision. Never mint fresh revisions here: the account's real
 * revision sequence belongs to the connectivity publisher, and outbidding it
 * would make genuine route invalidations look stale. */
export const PHONE_REPLY_NUDGE_REVISION = 1;

const REPLY_PREFIX = "phonereply:";

/** The subset of `DurableObjectStorage` the inbox uses (Map-backed in tests). */
export interface PhoneReplyStorage {
  get<T>(key: string): Promise<T | undefined>;
  put<T>(key: string, value: T): Promise<void>;
  delete(key: string): Promise<boolean>;
  list<T>(options: { prefix: string; limit?: number }): Promise<Map<string, T>>;
}

export type ParsePhoneReplyResult =
  | { ok: true; reply: Omit<StoredPhoneReply, "createdAtMs" | "expiresAtMs"> }
  | { ok: false; error: string };

function boundedId(value: unknown, maxChars: number): string | null {
  if (typeof value !== "string") return null;
  const text = value.trim();
  if (!text || text.length > maxChars) return null;
  return text;
}

/** Strictly parse an enqueue body. Unknown keys are ignored (additive wire),
 * required keys are bounded, and text is required non-empty: an empty reply
 * has nothing to type. */
export function parsePhoneReply(body: Record<string, unknown>): ParsePhoneReplyResult {
  const replyId = boundedId(body.replyId, MAX_PHONE_REPLY_ID_CHARS);
  if (!replyId) return { ok: false, error: "invalid_reply_id" };
  const macDeviceId = boundedId(body.macDeviceId, MAX_PHONE_REPLY_TARGET_ID_CHARS);
  if (!macDeviceId) return { ok: false, error: "invalid_mac_device_id" };
  const surfaceId = boundedId(body.surfaceId, MAX_PHONE_REPLY_TARGET_ID_CHARS);
  if (!surfaceId) return { ok: false, error: "invalid_surface_id" };
  // The workspace claim is optional on old push payloads; the Mac re-resolves
  // the live owner of the surface anyway.
  const workspaceId = body.workspaceId == null
    ? ""
    : boundedId(body.workspaceId, MAX_PHONE_REPLY_TARGET_ID_CHARS);
  if (workspaceId === null) return { ok: false, error: "invalid_workspace_id" };
  const notificationId = body.notificationId == null
    ? ""
    : boundedId(body.notificationId, MAX_PHONE_REPLY_TARGET_ID_CHARS);
  if (notificationId === null) return { ok: false, error: "invalid_notification_id" };
  if (typeof body.text !== "string") return { ok: false, error: "invalid_text" };
  const text = body.text;
  if (!text.trim()) return { ok: false, error: "invalid_text" };
  if (text.length > MAX_PHONE_REPLY_TEXT_CHARS) return { ok: false, error: "text_too_long" };
  return {
    ok: true,
    reply: { replyId, macDeviceId, workspaceId, surfaceId, notificationId, text },
  };
}

function replyKey(replyId: string): string {
  return `${REPLY_PREFIX}${replyId}`;
}

async function loadAll(storage: PhoneReplyStorage): Promise<Map<string, StoredPhoneReply>> {
  return storage.list<StoredPhoneReply>({ prefix: REPLY_PREFIX });
}

/** Delete expired entries; returns the live remainder. Pruning is lazy (on
 * every inbox op) instead of alarm-driven so this stays additive to the DO's
 * presence alarm schedule. */
async function pruneExpired(
  storage: PhoneReplyStorage,
  nowMs: number,
): Promise<StoredPhoneReply[]> {
  const all = await loadAll(storage);
  const live: StoredPhoneReply[] = [];
  for (const [key, reply] of all) {
    if (reply.expiresAtMs <= nowMs) {
      await storage.delete(key);
    } else {
      live.push(reply);
    }
  }
  live.sort((a, b) => a.createdAtMs - b.createdAtMs);
  return live;
}

export type EnqueuePhoneReplyResult =
  | {
      ok: true;
      duplicate: boolean;
      pending: number;
      expiresAtMs: number;
      /** Live subscriber sockets the enqueue nudge reached. Diagnostic only:
       * 0 is not failure (the Mac also sweeps on stream start and app
       * activation), but it tells a debugging session whether the account had
       * any live channel at enqueue time. */
      nudged?: number;
    }
  | { ok: false; error: "too_many_pending" };

/** Park one reply. Idempotent on replyId: a retried POST (the phone's retry
 * ladder re-sends the same replyId) reports success without duplicating.
 * Past the per-account cap the OLDEST entries are evicted; the newest reply
 * is the user's most recent intent and always wins a slot. */
export async function enqueuePhoneReply(
  storage: PhoneReplyStorage,
  reply: Omit<StoredPhoneReply, "createdAtMs" | "expiresAtMs">,
  nowMs: number,
): Promise<EnqueuePhoneReplyResult> {
  const live = await pruneExpired(storage, nowMs);
  const existing = live.find((entry) => entry.replyId === reply.replyId);
  if (existing) {
    return {
      ok: true,
      duplicate: true,
      pending: live.length,
      expiresAtMs: existing.expiresAtMs,
    };
  }
  let pending = live;
  while (pending.length >= MAX_PENDING_PHONE_REPLIES) {
    const oldest = pending[0];
    if (!oldest) break;
    await storage.delete(replyKey(oldest.replyId));
    pending = pending.slice(1);
  }
  const stored: StoredPhoneReply = {
    ...reply,
    createdAtMs: nowMs,
    expiresAtMs: nowMs + PHONE_REPLY_TTL_MS,
  };
  await storage.put(replyKey(reply.replyId), stored);
  return {
    ok: true,
    duplicate: false,
    pending: pending.length + 1,
    expiresAtMs: stored.expiresAtMs,
  };
}

/** Pending, unexpired replies for one Mac, oldest first (typing order). */
export async function listPhoneReplies(
  storage: PhoneReplyStorage,
  macDeviceId: string,
  nowMs: number,
): Promise<StoredPhoneReply[]> {
  const live = await pruneExpired(storage, nowMs);
  return live.filter((reply) => reply.macDeviceId === macDeviceId);
}

/** Remove acknowledged replies. Unknown ids are a no-op (already expired or
 * acked by a previous sweep), so the Mac can ack the same batch twice safely. */
export async function ackPhoneReplies(
  storage: PhoneReplyStorage,
  replyIds: string[],
  nowMs: number,
): Promise<{ removed: number }> {
  await pruneExpired(storage, nowMs);
  let removed = 0;
  for (const replyId of replyIds) {
    const bounded = boundedId(replyId, MAX_PHONE_REPLY_ID_CHARS);
    if (!bounded) continue;
    if (await storage.delete(replyKey(bounded))) removed += 1;
  }
  return { removed };
}

export type ParseAckResult = { ok: true; replyIds: string[] } | { ok: false; error: string };

export function parsePhoneReplyAck(body: Record<string, unknown>): ParseAckResult {
  if (!Array.isArray(body.replyIds) || body.replyIds.length === 0) {
    return { ok: false, error: "invalid_reply_ids" };
  }
  if (body.replyIds.length > MAX_PENDING_PHONE_REPLIES * 2) {
    return { ok: false, error: "invalid_reply_ids" };
  }
  const replyIds: string[] = [];
  for (const value of body.replyIds) {
    const bounded = boundedId(value, MAX_PHONE_REPLY_ID_CHARS);
    if (!bounded) return { ok: false, error: "invalid_reply_ids" };
    replyIds.push(bounded);
  }
  return { ok: true, replyIds };
}
