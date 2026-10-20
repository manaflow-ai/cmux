import { describe, expect, test } from "bun:test";
import * as zlib from "node:zlib";
import {
  readTranscriptHeadBatch,
  TRANSCRIPT_HEAD_DECOMPRESSED_BYTE_LIMIT,
  TRANSCRIPT_HEAD_MESSAGE_LIMIT,
} from "../services/vault/transcript-head";
import {
  extractTranscriptMessages,
  TranscriptLineParser,
  type TranscriptMessage,
} from "../services/vault/transcript";

describe("vault transcript head batch", () => {
  test("caps by message count and marks incomplete when more messages exist", async () => {
    const jsonl = jsonlMessages(10);
    const fullMessages = extractTranscriptMessages(jsonl);

    const batch = await readTranscriptHeadBatch(zstdStream(jsonl, 11), {
      maxMessages: 3,
      maxDecompressedBytes: TRANSCRIPT_HEAD_DECOMPRESSED_BYTE_LIMIT,
    });

    expect(batch.complete).toBe(false);
    expect(batch.messages).toEqual(fullMessages.slice(0, 3));
  });

  test("caps by decompressed bytes", async () => {
    const jsonl = jsonlMessages(20, (index) => `message ${index} ${"x".repeat(32)}`);
    const fullMessages = extractTranscriptMessages(jsonl);

    const batch = await readTranscriptHeadBatch(zstdStream(jsonl, 7), {
      maxMessages: TRANSCRIPT_HEAD_MESSAGE_LIMIT,
      maxDecompressedBytes: 128,
    });

    expect(batch.complete).toBe(false);
    expect(batch.decompressedBytes).toBe(128);
    expect(batch.messages.length).toBeGreaterThan(0);
    expect(batch.messages).toEqual(fullMessages.slice(0, batch.messages.length));
  });

  test("reports complete when the stream ends at the message cap", async () => {
    const jsonl = jsonlMessages(3);

    const batch = await readTranscriptHeadBatch(zstdStream(jsonl, 5), {
      maxMessages: 3,
      maxDecompressedBytes: TRANSCRIPT_HEAD_DECOMPRESSED_BYTE_LIMIT,
    });

    expect(batch.complete).toBe(true);
    expect(batch.messages).toEqual(extractTranscriptMessages(jsonl));
  });

  test("matches the incremental parser prefix for the same input", async () => {
    const jsonl = jsonlMessages(12, (index) =>
      index % 2 === 0 ? `assistant line ${index}` : `user line ${index}`,
    );
    const parserMessages: TranscriptMessage[] = [];
    const parser = new TranscriptLineParser((message) => parserMessages.push(message));
    for (const chunk of stringChunks(jsonl, 13)) parser.feed(chunk);
    parser.finish();

    const batch = await readTranscriptHeadBatch(zstdStream(jsonl, 9), {
      maxMessages: 5,
      maxDecompressedBytes: TRANSCRIPT_HEAD_DECOMPRESSED_BYTE_LIMIT,
    });

    expect(batch.complete).toBe(false);
    expect(batch.messages).toEqual(parserMessages.slice(0, 5));
  });
});

function jsonlMessages(
  count: number,
  textForIndex: (index: number) => string = (index) => `message ${index}`,
): string {
  return Array.from({ length: count }, (_, index) =>
    `${JSON.stringify({
      role: index % 2 === 0 ? "assistant" : "user",
      content: textForIndex(index),
    })}\n`,
  ).join("");
}

function zstdStream(jsonl: string, chunkSize: number): ReadableStream<Uint8Array> {
  const { zstdCompressSync } = zlib as unknown as {
    readonly zstdCompressSync: (input: Uint8Array) => Uint8Array;
  };
  const compressed = zstdCompressSync(Buffer.from(jsonl));
  return bytesStream(new Uint8Array(compressed), chunkSize);
}

function bytesStream(
  bytes: Uint8Array,
  chunkSize: number,
): ReadableStream<Uint8Array> {
  let offset = 0;
  return new ReadableStream<Uint8Array>({
    pull(controller) {
      if (offset >= bytes.length) {
        controller.close();
        return;
      }
      const end = Math.min(offset + chunkSize, bytes.length);
      controller.enqueue(bytes.subarray(offset, end));
      offset = end;
    },
    cancel() {
      offset = bytes.length;
    },
  });
}

function stringChunks(value: string, chunkSize: number): readonly string[] {
  const chunks: string[] = [];
  for (let offset = 0; offset < value.length; offset += chunkSize) {
    chunks.push(value.slice(offset, offset + chunkSize));
  }
  return chunks;
}
