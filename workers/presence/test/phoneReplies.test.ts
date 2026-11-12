import { describe, expect, it } from "bun:test";
import {
  ackPhoneReplies,
  enqueuePhoneReply,
  listPhoneReplies,
  MAX_PENDING_PHONE_REPLIES,
  parsePhoneReply,
  parsePhoneReplyAck,
  PHONE_REPLY_TTL_MS,
  type PhoneReplyStorage,
  type PhoneReplyTarget,
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

const baseTuple = {
  accountID: "account-1",
  teamID: "team-1",
  iosBuildID: "ios-build-1",
  iosInstallationID: "ios-install-1",
  macDeviceID: "mac-1",
  macInstanceTag: "nightly",
  macBuildID: "mac-build-1",
};

function b64(bytes: number): string {
  return btoa(String.fromCharCode(...new Uint8Array(bytes)));
}

function replyBody(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    replyId: "reply-1",
    macDeviceId: "mac-1",
    macInstanceTag: "nightly",
    encryptedPayload: {
      installationID: "mac-install-1",
      keyID: "reply-key-1",
      version: 2,
      senderKeyID: "phone-key-1",
      encapsulatedKey: b64(32),
      ciphertext: b64(32),
      tuple: { ...baseTuple },
    },
    ...overrides,
  };
}

function parsedReply(overrides: Record<string, unknown> = {}) {
  const parsed = parsePhoneReply(replyBody(overrides), { accountID: "account-1" });
  if (!parsed.ok) throw new Error(`parse failed: ${parsed.error}`);
  return parsed.reply;
}

function target(overrides: Partial<PhoneReplyTarget> = {}): PhoneReplyTarget {
  return {
    macDeviceId: "mac-1",
    macInstanceTag: "nightly",
    macBuildID: "mac-build-1",
    ...overrides,
  };
}

describe("parsePhoneReply", () => {
  it("accepts the strict encrypted envelope and normalizes ids", () => {
    const parsed = parsePhoneReply(
      replyBody({ replyId: " reply-1 " }),
      { accountID: "account-1" },
    );
    expect(parsed.ok).toBe(true);
    if (parsed.ok) {
      expect(parsed.reply.replyId).toBe("reply-1");
      expect(parsed.reply.encryptedPayload.tuple.accountID).toBe("account-1");
      expect(parsed.reply.encryptedPayload.installationID).toBe("mac-install-1");
      expect(parsed.reply.encryptedPayload.tuple.iosInstallationID).toBe("ios-install-1");
      expect(parsed.reply.encryptedPayload.ciphertext).toBe(b64(32));
    }
  });

  it("accepts absent optional tuple members as null", () => {
    const body = replyBody({ macInstanceTag: undefined });
    const payload = body.encryptedPayload as Record<string, unknown>;
    payload.tuple = {
      accountID: "account-1",
      iosBuildID: "ios-build-1",
      iosInstallationID: "ios-install-1",
      macDeviceID: "mac-1",
      macBuildID: "mac-build-1",
    };
    const parsed = parsePhoneReply(body, { accountID: "account-1" });
    expect(parsed.ok).toBe(true);
    if (parsed.ok) {
      expect(parsed.reply.macInstanceTag).toBeNull();
      expect(parsed.reply.encryptedPayload.tuple.macInstanceTag).toBeNull();
      expect(parsed.reply.encryptedPayload.tuple.macBuildID).toBe("mac-build-1");
    }
  });

  it("rejects plaintext, unknown envelope fields, and malformed crypto fields", () => {
    expect(parsePhoneReply({ ...replyBody(), text: "plaintext" }).ok).toBe(false);
    expect(parsePhoneReply({ ...replyBody(), extra: true }).ok).toBe(false);
    expect(parsePhoneReply({
      ...replyBody(),
      encryptedPayload: { ...(replyBody().encryptedPayload as object), ciphertext: "plain text" },
    }).ok).toBe(false);
    expect(parsePhoneReply({
      ...replyBody(),
      encryptedPayload: { ...(replyBody().encryptedPayload as object), tuple: { ...baseTuple, accountID: undefined } },
    }).ok).toBe(false);
  });

  it("requires tuple context to match the authenticated account and outer target", () => {
    expect(parsePhoneReply(replyBody(), { accountID: "other-account" }).ok).toBe(false);
    expect(parsePhoneReply({
      ...replyBody(),
      macInstanceTag: "stable",
    }, { accountID: "account-1" }).ok).toBe(false);
    expect(parsePhoneReply({
      ...replyBody(),
      encryptedPayload: {
        ...(replyBody().encryptedPayload as object),
        tuple: { ...baseTuple, macBuildID: "other-build" },
      },
    }, { accountID: "account-1", target: target() }).ok).toBe(false);
  });

  it("rejects missing required crypto and tuple fields", () => {
    expect(parsePhoneReply({ ...replyBody(), encryptedPayload: undefined }).ok).toBe(false);
    expect(parsePhoneReply({
      ...replyBody(),
      encryptedPayload: {
        ...(replyBody().encryptedPayload as object),
        tuple: { ...baseTuple, iosBuildID: undefined },
      },
    }).ok).toBe(false);
    expect(parsePhoneReply({
      ...replyBody(),
      encryptedPayload: {
        ...(replyBody().encryptedPayload as object),
        tuple: { ...baseTuple, macBuildID: undefined },
      },
    }).ok).toBe(false);
    expect(parsePhoneReply({
      ...replyBody(),
      encryptedPayload: {
        ...(replyBody().encryptedPayload as object),
        encapsulatedKey: b64(31),
      },
    }).ok).toBe(false);
  });
});

describe("enqueue/list/ack", () => {
  it("parks and lists only for the exact Mac device, instance tag, and build", async () => {
    const storage = makeStorage();
    const now = 1_000_000;
    await enqueuePhoneReply(storage, parsedReply(), now);

    expect(await listPhoneReplies(storage, target(), now)).toHaveLength(1);
    expect(await listPhoneReplies(storage, target({ macInstanceTag: "stable" }), now)).toHaveLength(0);
    expect(await listPhoneReplies(storage, target({ macBuildID: "other-build" }), now)).toHaveLength(0);
    expect(await listPhoneReplies(storage, target({ macDeviceId: "other-mac" }), now)).toHaveLength(0);
  });

  it("deduplicates an identical retry and rejects ciphertext conflicts", async () => {
    const storage = makeStorage();
    const now = 1_000_000;
    const reply = parsedReply();
    const first = await enqueuePhoneReply(storage, reply, now);
    const retried = await enqueuePhoneReply(storage, reply, now + 5_000);
    expect(first).toEqual({
      ok: true,
      duplicate: false,
      pending: 1,
      expiresAtMs: now + PHONE_REPLY_TTL_MS,
    });
    expect(retried).toEqual({
      ok: true,
      duplicate: true,
      pending: 1,
      expiresAtMs: now + PHONE_REPLY_TTL_MS,
    });

    const conflict = await enqueuePhoneReply(storage, {
      ...reply,
      encryptedPayload: { ...reply.encryptedPayload, ciphertext: b64(48) },
    }, now + 6_000);
    expect(conflict).toEqual({ ok: false, error: "reply_id_conflict" });
    expect(await listPhoneReplies(storage, target(), now + 6_000)).toHaveLength(1);
  });

  it("acks only the selected target and remains idempotent", async () => {
    const storage = makeStorage();
    const now = 1_000_000;
    await enqueuePhoneReply(storage, parsedReply(), now);

    expect(await ackPhoneReplies(storage, ["reply-1"], target({ macInstanceTag: "stable" }), now))
      .toEqual({ removed: 0 });
    expect(await ackPhoneReplies(storage, ["reply-1"], target(), now)).toEqual({ removed: 1 });
    expect(await ackPhoneReplies(storage, ["reply-1"], target(), now)).toEqual({ removed: 0 });
  });

  it("expires entries and removes malformed legacy plaintext records", async () => {
    const storage = makeStorage();
    const now = 1_000_000;
    await enqueuePhoneReply(storage, parsedReply(), now);
    await storage.put("phonereply:e2e:legacy", {
      replyId: "legacy",
      macDeviceId: "mac-1",
      text: "plaintext",
      createdAtMs: now,
      expiresAtMs: now + PHONE_REPLY_TTL_MS,
    });
    expect(await listPhoneReplies(storage, target(), now + PHONE_REPLY_TTL_MS)).toHaveLength(0);
    expect(await storage.get("phonereply:e2e:legacy")).toBeUndefined();
  });

  it("evicts oldest past the pending cap while retaining the newest reply", async () => {
    const storage = makeStorage();
    const now = 1_000_000;
    for (let index = 0; index < MAX_PENDING_PHONE_REPLIES + 3; index += 1) {
      await enqueuePhoneReply(storage, parsedReply({ replyId: `reply-${index}` }), now + index);
    }
    const pending = await listPhoneReplies(storage, target(), now + 100);
    expect(pending).toHaveLength(MAX_PENDING_PHONE_REPLIES);
    expect(pending[0]?.replyId).toBe("reply-3");
    expect(pending.at(-1)?.replyId).toBe(`reply-${MAX_PENDING_PHONE_REPLIES + 2}`);
  });

  it("lists oldest first", async () => {
    const storage = makeStorage();
    const now = 1_000_000;
    for (const [offset, id] of [[20, "later"], [0, "earliest"], [10, "middle"]] as const) {
      await enqueuePhoneReply(storage, parsedReply({ replyId: id }), now + offset);
    }
    expect((await listPhoneReplies(storage, target(), now + 100)).map(
      (reply: StoredPhoneReply) => reply.replyId,
    )).toEqual(["earliest", "middle", "later"]);
  });
});

describe("parsePhoneReplyAck", () => {
  it("requires bounded ids and a complete target when used by the handler", () => {
    expect(parsePhoneReplyAck({
      replyIds: ["a", "b"],
      macDeviceId: "mac-1",
      macInstanceTag: "nightly",
      macBuildID: "mac-build-1",
    })).toEqual({
      ok: true,
      replyIds: ["a", "b"],
      target: target(),
    });
    expect(parsePhoneReplyAck({ replyIds: [] }).ok).toBe(false);
    expect(parsePhoneReplyAck({ replyIds: ["", "b"] }).ok).toBe(false);
    expect(parsePhoneReplyAck({ replyIds: "a" }).ok).toBe(false);
    expect(parsePhoneReplyAck({
      replyIds: ["a"],
      macDeviceId: "mac-1",
      macInstanceTag: "nightly",
    }).ok).toBe(false);
  });
});
