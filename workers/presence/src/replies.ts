// Phone reply inbox: the worker stores only an opaque, strictly validated
// encrypted envelope. Authentication and account selection happen before the
// request reaches the account Durable Object.

export interface PhoneReplyTuple {
  accountID: string;
  teamID: string | null;
  iosBuildID: string;
  iosInstallationID: string;
  macDeviceID: string;
  macInstanceTag: string | null;
  macBuildID: string;
}

export interface PhoneReplyEncryptedPayload {
  installationID: string;
  keyID: string;
  version: 2;
  senderKeyID: string;
  encapsulatedKey: string;
  ciphertext: string;
  tuple: PhoneReplyTuple;
}

export interface StoredPhoneReply {
  replyId: string;
  macDeviceId: string;
  macInstanceTag: string | null;
  encryptedPayload: PhoneReplyEncryptedPayload;
  createdAtMs: number;
  expiresAtMs: number;
}

export interface PhoneReplyTarget {
  macDeviceId: string;
  macInstanceTag: string | null;
  macBuildID: string | null;
}

export interface PhoneReplyParseContext {
  accountID?: string;
  target?: PhoneReplyTarget;
}

export const PHONE_REPLY_TTL_MS = 15 * 60 * 1000;
export const MAX_PENDING_PHONE_REPLIES = 20;
export const MAX_PHONE_REPLY_TEXT_CHARS = 8_192;
export const MAX_PHONE_REPLY_ID_CHARS = 64;
export const MAX_PHONE_REPLY_TARGET_ID_CHARS = 128;
export const MAX_PHONE_REPLY_BODY_BYTES = 64 * 1024;
export const PHONE_REPLY_NUDGE_REVISION = 1;

const REPLY_PREFIX = "phonereply:e2e:";
const MAX_ENCRYPTED_FIELD_CHARS = 64 * 1024;
const MAX_KEY_ID_CHARS = 128;
const MAX_DECODED_CIPHERTEXT_BYTES = MAX_PHONE_REPLY_BODY_BYTES;

export interface PhoneReplyStorage {
  get<T>(key: string): Promise<T | undefined>;
  put<T>(key: string, value: T): Promise<void>;
  delete(key: string): Promise<boolean>;
  list<T>(options: { prefix: string; limit?: number }): Promise<Map<string, T>>;
}

export type ParsePhoneReplyResult =
  | { ok: true; reply: Omit<StoredPhoneReply, "createdAtMs" | "expiresAtMs"> }
  | { ok: false; error: string };

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function hasOnlyKeys(value: Record<string, unknown>, keys: readonly string[]): boolean {
  const allowed = new Set(keys);
  return Object.keys(value).every((key) => allowed.has(key));
}

function boundedId(value: unknown, maxChars: number): string | null {
  if (typeof value !== "string") return null;
  const text = value.trim();
  if (!text || text.length > maxChars) return null;
  return text;
}

function optionalId(value: unknown, maxChars: number): string | null | undefined {
  if (value === undefined || value === null) return null;
  return boundedId(value, maxChars);
}

function validBase64(value: unknown, minBytes: number, maxBytes: number): value is string {
  if (typeof value !== "string" || value.length > MAX_ENCRYPTED_FIELD_CHARS) return false;
  if (!/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value)) {
    return false;
  }
  try {
    const bytes = atob(value).length;
    return bytes >= minBytes && bytes <= maxBytes;
  } catch {
    return false;
  }
}

function parseTuple(value: unknown): PhoneReplyTuple | null {
  if (!isRecord(value) || !hasOnlyKeys(value, [
    "accountID", "teamID", "iosBuildID", "iosInstallationID",
    "macDeviceID", "macInstanceTag", "macBuildID",
  ])) return null;
  const accountID = boundedId(value.accountID, MAX_PHONE_REPLY_TARGET_ID_CHARS);
  const iosBuildID = boundedId(value.iosBuildID, MAX_PHONE_REPLY_TARGET_ID_CHARS);
  const iosInstallationID = boundedId(value.iosInstallationID, MAX_PHONE_REPLY_TARGET_ID_CHARS);
  const macDeviceID = boundedId(value.macDeviceID, MAX_PHONE_REPLY_TARGET_ID_CHARS);
  const teamID = optionalId(value.teamID, MAX_PHONE_REPLY_TARGET_ID_CHARS);
  const macInstanceTag = optionalId(value.macInstanceTag, MAX_PHONE_REPLY_TARGET_ID_CHARS);
  const macBuildID = boundedId(value.macBuildID, MAX_PHONE_REPLY_TARGET_ID_CHARS);
  if (!accountID || !iosBuildID || !iosInstallationID || !macDeviceID) return null;
  if (teamID === undefined || macInstanceTag === undefined || !macBuildID) return null;
  return { accountID, teamID, iosBuildID, iosInstallationID, macDeviceID, macInstanceTag, macBuildID };
}

function parseEncryptedPayload(value: unknown): PhoneReplyEncryptedPayload | null {
  if (!isRecord(value) || !hasOnlyKeys(value, [
    "installationID", "keyID", "version", "senderKeyID", "encapsulatedKey", "ciphertext", "tuple",
  ])) return null;
  const installationID = boundedId(value.installationID, MAX_PHONE_REPLY_TARGET_ID_CHARS);
  const keyID = boundedId(value.keyID, MAX_KEY_ID_CHARS);
  const senderKeyID = boundedId(value.senderKeyID, MAX_KEY_ID_CHARS);
  const tuple = parseTuple(value.tuple);
  if (!installationID || !keyID || !senderKeyID || value.version !== 2 || !tuple) return null;
  if (!validBase64(value.encapsulatedKey, 32, 32)) return null;
  if (!validBase64(value.ciphertext, 16, MAX_DECODED_CIPHERTEXT_BYTES)) return null;
  return {
    installationID,
    keyID,
    version: 2,
    senderKeyID,
    encapsulatedKey: value.encapsulatedKey,
    ciphertext: value.ciphertext,
    tuple,
  };
}

function sameTarget(a: PhoneReplyTarget, b: PhoneReplyTarget): boolean {
  return a.macDeviceId === b.macDeviceId
    && a.macInstanceTag === b.macInstanceTag
    && a.macBuildID === b.macBuildID;
}

function targetForReply(
  reply: Pick<StoredPhoneReply, "macDeviceId" | "macInstanceTag" | "encryptedPayload">,
): PhoneReplyTarget {
  return {
    macDeviceId: reply.macDeviceId,
    macInstanceTag: reply.macInstanceTag,
    macBuildID: reply.encryptedPayload.tuple.macBuildID,
  };
}

export function parsePhoneReply(
  body: Record<string, unknown>,
  context: PhoneReplyParseContext = {},
): ParsePhoneReplyResult {
  if (!isRecord(body) || !hasOnlyKeys(body, [
    "replyId", "macDeviceId", "macInstanceTag", "encryptedPayload",
  ])) return { ok: false, error: "invalid_reply_envelope" };

  const replyId = boundedId(body.replyId, MAX_PHONE_REPLY_ID_CHARS);
  const macDeviceId = boundedId(body.macDeviceId, MAX_PHONE_REPLY_TARGET_ID_CHARS);
  const macInstanceTag = optionalId(body.macInstanceTag, MAX_PHONE_REPLY_TARGET_ID_CHARS);
  const encryptedPayload = parseEncryptedPayload(body.encryptedPayload);
  if (!replyId) return { ok: false, error: "invalid_reply_id" };
  if (!macDeviceId) return { ok: false, error: "invalid_mac_device_id" };
  if (macInstanceTag === undefined) return { ok: false, error: "invalid_mac_instance_tag" };
  if (!encryptedPayload) return { ok: false, error: "invalid_encrypted_payload" };
  if (encryptedPayload.tuple.macDeviceID !== macDeviceId
    || encryptedPayload.tuple.macInstanceTag !== macInstanceTag) {
    return { ok: false, error: "reply_target_mismatch" };
  }
  if (context.accountID !== undefined && encryptedPayload.tuple.accountID !== context.accountID) {
    return { ok: false, error: "account_mismatch" };
  }
  if (context.target && !sameTarget(context.target, targetForReply({
    macDeviceId,
    macInstanceTag,
    encryptedPayload,
  }))) return { ok: false, error: "reply_target_mismatch" };

  return { ok: true, reply: { replyId, macDeviceId, macInstanceTag, encryptedPayload } };
}

function replyKey(replyId: string): string {
  return `${REPLY_PREFIX}${replyId}`;
}

async function loadAll(storage: PhoneReplyStorage): Promise<Map<string, StoredPhoneReply>> {
  return storage.list<StoredPhoneReply>({ prefix: REPLY_PREFIX });
}

function validStoredReply(reply: unknown): reply is StoredPhoneReply {
  if (!isRecord(reply) || typeof reply.createdAtMs !== "number" || typeof reply.expiresAtMs !== "number") {
    return false;
  }
  const parsed = parsePhoneReply({
    replyId: reply.replyId,
    macDeviceId: reply.macDeviceId,
    macInstanceTag: reply.macInstanceTag,
    encryptedPayload: reply.encryptedPayload,
  });
  return parsed.ok && Number.isFinite(reply.createdAtMs) && Number.isFinite(reply.expiresAtMs);
}

async function pruneExpired(storage: PhoneReplyStorage, nowMs: number): Promise<StoredPhoneReply[]> {
  const all = await loadAll(storage);
  const live: StoredPhoneReply[] = [];
  for (const [key, value] of all) {
    if (!validStoredReply(value) || value.expiresAtMs <= nowMs) {
      await storage.delete(key);
    } else {
      live.push(value);
    }
  }
  live.sort((a, b) => a.createdAtMs - b.createdAtMs);
  return live;
}

export type EnqueuePhoneReplyResult =
  | { ok: true; duplicate: boolean; pending: number; expiresAtMs: number; nudged?: number }
  | { ok: false; error: "too_many_pending" | "reply_id_conflict" | "account_mismatch" };

function sameEnvelope(
  a: StoredPhoneReply,
  b: Omit<StoredPhoneReply, "createdAtMs" | "expiresAtMs">,
): boolean {
  return a.macDeviceId === b.macDeviceId
    && a.macInstanceTag === b.macInstanceTag
    && JSON.stringify(a.encryptedPayload) === JSON.stringify(b.encryptedPayload);
}

export async function enqueuePhoneReply(
  storage: PhoneReplyStorage,
  reply: Omit<StoredPhoneReply, "createdAtMs" | "expiresAtMs">,
  nowMs: number,
): Promise<EnqueuePhoneReplyResult> {
  const live = await pruneExpired(storage, nowMs);
  const existing = live.find((entry) => entry.replyId === reply.replyId);
  if (existing) {
    if (!sameEnvelope(existing, reply)) return { ok: false, error: "reply_id_conflict" };
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

export async function listPhoneReplies(
  storage: PhoneReplyStorage,
  target: PhoneReplyTarget,
  nowMs: number,
): Promise<StoredPhoneReply[]> {
  const live = await pruneExpired(storage, nowMs);
  return live.filter((reply) => sameTarget(targetForReply(reply), target));
}

export async function ackPhoneReplies(
  storage: PhoneReplyStorage,
  replyIds: string[],
  target: PhoneReplyTarget,
  nowMs: number,
): Promise<{ removed: number }> {
  const live = await pruneExpired(storage, nowMs);
  const byId = new Map(live.map((reply) => [reply.replyId, reply]));
  let removed = 0;
  for (const replyId of replyIds) {
    const bounded = boundedId(replyId, MAX_PHONE_REPLY_ID_CHARS);
    const reply = bounded ? byId.get(bounded) : undefined;
    if (bounded && reply && sameTarget(targetForReply(reply), target)
      && await storage.delete(replyKey(bounded))) {
      removed += 1;
    }
  }
  return { removed };
}

export type ParseAckResult =
  | { ok: true; replyIds: string[]; target?: PhoneReplyTarget }
  | { ok: false; error: string };

export function parsePhoneReplyAck(body: Record<string, unknown>): ParseAckResult {
  if (!isRecord(body) || !hasOnlyKeys(body, [
    "replyIds", "macDeviceId", "macInstanceTag", "macBuildID",
  ])) return { ok: false, error: "invalid_reply_ids" };
  if (!Array.isArray(body.replyIds) || body.replyIds.length === 0
    || body.replyIds.length > MAX_PENDING_PHONE_REPLIES * 2) {
    return { ok: false, error: "invalid_reply_ids" };
  }
  const replyIds: string[] = [];
  for (const value of body.replyIds) {
    const bounded = boundedId(value, MAX_PHONE_REPLY_ID_CHARS);
    if (!bounded) return { ok: false, error: "invalid_reply_ids" };
    replyIds.push(bounded);
  }
  if (!Object.prototype.hasOwnProperty.call(body, "macDeviceId")) {
    return { ok: true, replyIds };
  }
  const target = parsePhoneReplyTarget(body);
  if (!target) return { ok: false, error: "invalid_reply_target" };
  return { ok: true, replyIds, target };
}

export function parsePhoneReplyTarget(body: Record<string, unknown>): PhoneReplyTarget | null {
  const macDeviceId = boundedId(body.macDeviceId, MAX_PHONE_REPLY_TARGET_ID_CHARS);
  const macInstanceTag = optionalId(body.macInstanceTag, MAX_PHONE_REPLY_TARGET_ID_CHARS);
  const macBuildID = boundedId(body.macBuildID, MAX_PHONE_REPLY_TARGET_ID_CHARS);
  if (!macDeviceId || macInstanceTag === undefined || !macBuildID) return null;
  return { macDeviceId, macInstanceTag, macBuildID };
}
