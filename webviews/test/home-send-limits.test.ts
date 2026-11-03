import { expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { DaemonHomeClient } from "../src/pages/home-channels/daemonHome";
import { TextUpload } from "../src/pages/home-channels/textUpload";
import { AttachmentService } from "../src/pages/home-channels/attachmentService";
import { HomeOps, type HomeAttachment } from "../src/pages/home-channels/types";
import type { DaemonSocket } from "../src/pages/shared/daemonSocket";

type Json = Record<string, unknown>;

/** Only the socket is replaced: exercise the actual page client, text preparation, hashing,
 * chunk upload and grouping against the owner's existing per-message protocol rules. */
function owner(cloud = false) {
  const messages = new Map<string, Json>();
  const blobs = new Map<string, Buffer>();
  const records = new Map<string, { mime_type: string; byte_count: number }>();
  const uploads = new Map<string, { hash: string; size: number; mimeType: string; chunks: Buffer[] }>();
  const chunks: number[] = [];
  const commands: string[] = [];
  let interrupt = false;
  let begins = 0;
  const socket = {
    async request(command: string, params: Json = {}): Promise<unknown> {
      commands.push(command);
      if (command === "identify") return { capabilities: cloud ? ["ws-cloud-conversations-v1"] : [] };
      if (command === "conversation-list") return { conversations: [] };
      if (command === "cloud-session-status") return { state: "active", participant: "user_test" };
      if (command === "cloud-inbox-list")
        return { entries: [{ conversation: "conv_test", title: "Test", kind: "group" }] };
      if (command.endsWith("attachment-upload")) {
        if (params.op === "begin") {
          begins += 1;
          const hash = String(params.sha256);
          if (blobs.has(hash)) return { stored: records.get(hash) };
          const upload = `upload-${begins}`;
          uploads.set(upload, {
            hash,
            size: Number(params.byte_count),
            mimeType: String(params.mime_type),
            chunks: [],
          });
          return { upload, needs: ["original"] };
        }
        const pending = uploads.get(String(params.upload))!;
        if (params.op === "chunk") {
          const bytes = Buffer.from(String(params.data), "base64");
          expect(params.offset).toBe(pending.chunks.reduce((sum, chunk) => sum + chunk.length, 0));
          expect(bytes.length).toBeLessThanOrEqual(1024 * 1024);
          pending.chunks.push(bytes);
          chunks.push(bytes.length);
        } else if (params.op === "commit") {
          const bytes = Buffer.concat(pending.chunks);
          expect(bytes.length).toBe(pending.size);
          expect(createHash("sha256").update(bytes).digest("hex")).toBe(pending.hash);
          blobs.set(pending.hash, bytes);
          records.set(pending.hash, { mime_type: pending.mimeType, byte_count: pending.size });
          uploads.delete(String(params.upload));
        } else if (params.op === "cancel") uploads.delete(String(params.upload));
        return {};
      }
      if (!command.endsWith("conversation-op")) return {};
      const key = String(params.idempotency_key);
      const op = params.op as Json;
      const parts = op.parts as Json[];
      expect(parts.length).toBeGreaterThan(0);
      expect(parts.length).toBeLessThanOrEqual(16);
      expect(parts.reduce((size, part) => size + Buffer.byteLength(String(part.text ?? "")), 0)).toBeLessThanOrEqual(
        64 * 1024,
      );
      if (op.kind === "message.send") expect(op.client_msg_id).toBe(key);
      for (const part of parts) {
        const record = records.get(String(part.hash));
        if (record) {
          expect(part.mime_type).toBe(record.mime_type);
          expect(part.byte_count).toBe(record.byte_count);
        }
      }
      if (messages.has(key)) {
        expect(op).toEqual(messages.get(key)!);
        return { rev: messages.size, replayed: true };
      }
      messages.set(key, op);
      if (interrupt && messages.size === 2) {
        interrupt = false;
        throw new Error("answer lost after commit");
      }
      return { rev: messages.size };
    },
    onEvent: () => () => {},
    onClose: () => () => {},
  } as unknown as DaemonSocket;
  return {
    socket,
    client: new DaemonHomeClient(socket),
    messages,
    blobs,
    chunks,
    commands,
    seed(text: string, mimeType: string) {
      const bytes = Buffer.from(text);
      const hash = createHash("sha256").update(bytes).digest("hex");
      blobs.set(hash, bytes);
      records.set(hash, { mime_type: mimeType, byte_count: bytes.length });
    },
    interrupt: () => (interrupt = true),
  };
}

const file = (index: number): HomeAttachment => ({
  type: "attachment",
  hash: index.toString(16).padStart(64, "0"),
  name: `file-${index}.bin`,
  mimeType: "application/octet-stream",
  byteCount: 8 * 1024 ** 3 + index,
});

// Includes a surrogate pair at a text-source slice boundary and multi-byte characters throughout.
const largeText = "a".repeat(16_383) + "😀\n" + "héllo 世界\n".repeat(400_000) + "end";

for (const cloud of [false, true]) {
  test(`${cloud ? "cloud" : "local"} Home sends and edits multi-MiB text as exact chunked bytes`, async () => {
    const state = owner(cloud);
    if (cloud) await state.client.call(HomeOps.inbox, {});
    await state.client.call(HomeOps.send, {
      conversation: "conv_test",
      text: largeText,
      idempotencyKey: "large-text",
    });
    const attachment = (state.messages.get("large-text")!.parts as Json[])[0]!;
    expect(attachment.type).toBe("attachment");
    expect(attachment.mime_type).toBe("text/plain");
    expect(attachment.byte_count).toBeGreaterThan(4 * 1024 * 1024);
    expect(state.blobs.get(String(attachment.hash))!.toString("utf8")).toBe(largeText);
    expect(state.chunks.length).toBeGreaterThan(4);
    expect(state.commands).toContain(`${cloud ? "cloud" : "conversation"}-attachment-upload`);
    const uploaded = state.chunks.length;
    await state.client.call(HomeOps.edit, {
      conversation: "conv_test",
      message: "msg_test",
      text: largeText,
      idempotencyKey: "large-edit",
    });
    expect(state.messages.get("large-edit")!.parts).toEqual([attachment]);
    expect(state.chunks.length).toBe(uploaded); // Reuse the content-addressed blob on edit/retry.
  });
}

test("direct sends group 257 files, preserve thread targets, and resume after a lost answer", async () => {
  const state = owner();
  state.interrupt();
  const attachments = Array.from({ length: 257 }, (_, index) => file(index));
  const params = {
    conversation: "conv_test",
    text: "caption",
    attachments,
    threadRoot: "msg_root",
    replyTo: "msg_parent",
    idempotencyKey: "x".repeat(128),
  };
  await expect(state.client.call(HomeOps.send, params)).rejects.toThrow("answer lost");
  expect(state.messages.size).toBe(2);
  const reconnect = new DaemonHomeClient(state.socket);
  await reconnect.call(HomeOps.send, params);
  const parts = [...state.messages.values()].flatMap((message) => message.parts as Json[]);
  expect(parts.filter((part) => part.type === "text")).toEqual([{ type: "text", text: "caption" }]);
  expect(parts.filter((part) => part.type === "attachment").map((part) => part.name)).toEqual(
    attachments.map((attachment) => attachment.name),
  );
  for (const [key, message] of state.messages) {
    expect(key.length).toBeLessThanOrEqual(128);
    expect(message.thread_root).toBe("msg_root");
    expect(message.reply_to).toEqual({ message_id: "msg_parent", part_index: 0 });
  }
  expect(state.messages.size).toBe(17);
});

test("small Unicode text stays inline and empty sends still refuse", async () => {
  const state = owner();
  await state.client.call(HomeOps.send, { conversation: "conv_test", text: "é😀", idempotencyKey: "small" });
  expect(state.messages.get("small")!.parts).toEqual([{ type: "text", text: "é😀" }]);
  expect(state.commands.some((command) => command.endsWith("attachment-upload"))).toBe(false);
  await expect(state.client.call(HomeOps.send, { conversation: "conv_test", text: " " })).rejects.toThrow("text");
});

test("text upload encodes bounded pieces, reports byte progress and preserves arbitrary byte slices", async () => {
  const encode = TextEncoder.prototype.encode;
  let largest = 0;
  let source: TextUpload;
  let slice: Blob;
  try {
    TextEncoder.prototype.encode = function (input = "") {
      largest = Math.max(largest, input.length);
      return encode.call(this, input);
    };
    source = new TextUpload(largeText);
    slice = source.slice(16_382, 1024 * 1024 + 13);
  } finally {
    TextEncoder.prototype.encode = encode;
  }
  expect(largest).toBeLessThanOrEqual(16 * 1024);
  expect(source!.size).toBe(Buffer.byteLength(largeText));
  expect(Buffer.from(await slice!.arrayBuffer())).toEqual(Buffer.from(largeText).subarray(16_382, 1024 * 1024 + 13));
  const state = owner();
  const progress: number[] = [];
  const attachment = await new AttachmentService(state.client).uploadText("conv_test", source!, (next) => {
    expect(next.total).toBe(source!.size);
    progress.push(next.sent);
  });
  expect(progress.at(-1)).toBe(source!.size);
  expect(progress.length).toBeGreaterThan(4);
  expect(state.blobs.get(attachment.hash)!.toString("utf8")).toBe(largeText);
});

test("an aborted long send commits no message", async () => {
  const state = owner();
  const abort = new AbortController();
  abort.abort();
  await expect(
    state.client.call(HomeOps.send, { conversation: "conv_test", text: largeText }, { signal: abort.signal }),
  ).rejects.toThrow();
  expect(state.messages.size).toBe(0);
  expect(state.chunks.length).toBe(0);
});

test("long text reuses an identical uploaded file's kept type without resending bytes", async () => {
  const state = owner();
  state.seed(largeText, "text/markdown");
  await state.client.call(HomeOps.send, { conversation: "conv_test", text: largeText, idempotencyKey: "existing" });
  expect((state.messages.get("existing")!.parts as Json[])[0]!.mime_type).toBe("text/markdown");
  expect(state.chunks).toEqual([]);
});
