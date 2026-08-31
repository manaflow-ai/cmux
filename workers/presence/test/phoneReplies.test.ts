import { describe, expect, it } from "bun:test";
import {
  ackPhoneReplies,
  enqueuePhoneReply,
  listPhoneReplies,
  MAX_PENDING_PHONE_REPLIES,
  MAX_PHONE_REPLY_TEXT_CHARS,
  parsePhoneReply,
  parsePhoneReplyAck,
  PHONE_REPLY_TTL_MS,
  type PhoneReplyStorage,
  type StoredPhoneReply,
} from "../src/replies";

function makeStorage(): PhoneReplyStorage {
  const map = new Map<string, unknown>();
  return {
    async get<T>(key: string) {
      return map.get(key) as T | undefined;
    },
    async put<T>(key: string, value: T) {
      map.set(key, value);
    },
    async delete(key: string) {
      return map.delete(key);
    },
    async list<T>({ prefix }: { prefix: string }) {
      const out = new Map<string, T>();
      for (const [key, value] of map) {
        if (key.startsWith(prefix)) out.set(key, value as T);
      }
      return out;
    },
  };
}

function replyBody(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    replyId: "reply-1",
    macDeviceId: "mac-1",
    workspaceId: "ws-1",
    surfaceId: "surface-1",
    notificationId: "note-1",
    text: "looks good, merge it",
    ...overrides,
  };
}

describe("parsePhoneReply", () => {
  it("accepts a full reply and passes ids through trimmed", () => {
    const parsed = parsePhoneReply(replyBody({ replyId: " reply-1 " }));
    expect(parsed.ok).toBe(true);
    if (parsed.ok) {
      expect(parsed.reply.replyId).toBe("reply-1");
      expect(parsed.reply.text).toBe("looks good, merge it");
    }
  });

  it("tolerates missing optional claims but requires target + text", () => {
    const minimal = parsePhoneReply(replyBody({ workspaceId: undefined, notificationId: undefined }));
    expect(minimal.ok).toBe(true);
    expect(parsePhoneReply(replyBody({ surfaceId: "" })).ok).toBe(false);
    expect(parsePhoneReply(replyBody({ macDeviceId: undefined })).ok).toBe(false);
    expect(parsePhoneReply(replyBody({ text: "   " })).ok).toBe(false);
    expect(parsePhoneReply(replyBody({ text: 7 })).ok).toBe(false);
    expect(
      parsePhoneReply(replyBody({ text: "x".repeat(MAX_PHONE_REPLY_TEXT_CHARS + 1) })).ok,
    ).toBe(false);
  });

  it("preserves interior whitespace in the reply text", () => {
    const parsed = parsePhoneReply(replyBody({ text: "line one\nline two  " }));
    expect(parsed.ok).toBe(true);
    if (parsed.ok) expect(parsed.reply.text).toBe("line one\nline two  ");
  });
});

describe("enqueue/list/ack", () => {
  it("parks, lists for the target mac only, and acks idempotently", async () => {
    const storage = makeStorage();
    const now = 1_000_000;
    const parsed = parsePhoneReply(replyBody());
    if (!parsed.ok) throw new Error("parse failed");
    const enqueued = await enqueuePhoneReply(storage, parsed.reply, now);
    expect(enqueued).toEqual({
      ok: true,
      duplicate: false,
      pending: 1,
      expiresAtMs: now + PHONE_REPLY_TTL_MS,
    });

    expect(await listPhoneReplies(storage, "mac-1", now)).toHaveLength(1);
    expect(await listPhoneReplies(storage, "other-mac", now)).toHaveLength(0);

    expect(await ackPhoneReplies(storage, ["reply-1"], now)).toEqual({ removed: 1 });
    expect(await ackPhoneReplies(storage, ["reply-1"], now)).toEqual({ removed: 0 });
    expect(await listPhoneReplies(storage, "mac-1", now)).toHaveLength(0);
  });

  it("is idempotent on replyId so the phone's retry ladder cannot duplicate", async () => {
    const storage = makeStorage();
    const now = 1_000_000;
    const parsed = parsePhoneReply(replyBody());
    if (!parsed.ok) throw new Error("parse failed");
    await enqueuePhoneReply(storage, parsed.reply, now);
    const retried = await enqueuePhoneReply(storage, parsed.reply, now + 5_000);
    expect(retried.ok).toBe(true);
    if (retried.ok) {
      expect(retried.duplicate).toBe(true);
      expect(retried.pending).toBe(1);
    }
  });

  it("expires entries past their TTL", async () => {
    const storage = makeStorage();
    const now = 1_000_000;
    const parsed = parsePhoneReply(replyBody());
    if (!parsed.ok) throw new Error("parse failed");
    await enqueuePhoneReply(storage, parsed.reply, now);
    expect(await listPhoneReplies(storage, "mac-1", now + PHONE_REPLY_TTL_MS - 1)).toHaveLength(1);
    expect(await listPhoneReplies(storage, "mac-1", now + PHONE_REPLY_TTL_MS)).toHaveLength(0);
  });

  it("evicts oldest past the pending cap; the newest reply always parks", async () => {
    const storage = makeStorage();
    const now = 1_000_000;
    for (let index = 0; index < MAX_PENDING_PHONE_REPLIES + 3; index += 1) {
      const parsed = parsePhoneReply(replyBody({ replyId: `reply-${index}` }));
      if (!parsed.ok) throw new Error("parse failed");
      const result = await enqueuePhoneReply(storage, parsed.reply, now + index);
      expect(result.ok).toBe(true);
    }
    const pending = await listPhoneReplies(storage, "mac-1", now + 100);
    expect(pending).toHaveLength(MAX_PENDING_PHONE_REPLIES);
    expect(pending[0]?.replyId).toBe("reply-3");
    expect(pending.at(-1)?.replyId).toBe(`reply-${MAX_PENDING_PHONE_REPLIES + 2}`);
  });

  it("lists oldest first so the Mac types replies in send order", async () => {
    const storage = makeStorage();
    const now = 1_000_000;
    for (const [offset, id] of [
      [20, "later"],
      [0, "earliest"],
      [10, "middle"],
    ] as const) {
      const parsed = parsePhoneReply(replyBody({ replyId: id }));
      if (!parsed.ok) throw new Error("parse failed");
      await enqueuePhoneReply(storage, parsed.reply, now + offset);
    }
    const pending = await listPhoneReplies(storage, "mac-1", now + 100);
    expect(pending.map((reply: StoredPhoneReply) => reply.replyId)).toEqual([
      "earliest",
      "middle",
      "later",
    ]);
  });
});

describe("parsePhoneReplyAck", () => {
  it("requires a bounded, non-empty id array", () => {
    expect(parsePhoneReplyAck({ replyIds: ["a", "b"] })).toEqual({
      ok: true,
      replyIds: ["a", "b"],
    });
    expect(parsePhoneReplyAck({ replyIds: [] }).ok).toBe(false);
    expect(parsePhoneReplyAck({ replyIds: ["", "b"] }).ok).toBe(false);
    expect(parsePhoneReplyAck({ replyIds: "a" }).ok).toBe(false);
    expect(
      parsePhoneReplyAck({ replyIds: Array(MAX_PENDING_PHONE_REPLIES * 2 + 1).fill("a") }).ok,
    ).toBe(false);
  });
});
