import { describe, expect, test } from "bun:test";
import { randomBytes } from "node:crypto";
import * as zlib from "node:zlib";
import {
  decompressZstdPreviewStream,
  extractTranscriptMessages,
  fetchTranscriptPreview,
} from "../services/vault/transcript";

const { zstdCompressSync } = zlib as typeof zlib & {
  readonly zstdCompressSync: (input: Uint8Array) => Buffer;
};

describe("vault transcript preview extraction", () => {
  test("extracts claude, codex, and pi style JSONL messages while skipping garbage", () => {
    const jsonl = [
      "not-json",
      JSON.stringify({
        type: "assistant",
        message: {
          role: "assistant",
          content: [{ type: "text", text: "Claude answer" }],
        },
      }),
      JSON.stringify({
        role: "user",
        content: "Run the tests",
      }),
      JSON.stringify({
        payload: {
          role: "assistant",
          content: [{ text: "Pi first line" }, { text: "Pi second line" }],
        },
      }),
      JSON.stringify({
        payload: {
          content: "Missing role",
        },
      }),
    ].join("\n");

    expect(extractTranscriptMessages(jsonl).messages).toEqual([
      { role: "assistant", text: "Claude answer" },
      { role: "user", text: "Run the tests" },
      { role: "assistant", text: "Pi first line\nPi second line" },
    ]);
  });

  test("stops at the message cap", () => {
    const jsonl = [
      JSON.stringify({ role: "user", content: "one" }),
      JSON.stringify({ role: "assistant", content: "two" }),
      JSON.stringify({ role: "user", content: "three" }),
    ].join("\n");

    const preview = extractTranscriptMessages(jsonl, { maxMessages: 2 });

    expect(preview.messages).toEqual([
      { role: "user", text: "one" },
      { role: "assistant", text: "two" },
    ]);
    expect(preview.messageLimitReached).toBe(true);
  });

  test("fetches transcript previews from a streamed zstd response", async () => {
    const originalFetch = globalThis.fetch;
    const compressed = zstdCompressSync(
      Buffer.from(`${JSON.stringify({ role: "assistant", content: "streamed preview" })}\n`),
    );

    globalThis.fetch = (() =>
      Promise.resolve(
        new Response(chunkedStream(compressed, 3), {
          status: 200,
        }),
      )) as typeof fetch;

    try {
      const preview = await fetchTranscriptPreview("https://vault.example/transcript.zst");

      expect(preview.messages).toEqual([{ role: "assistant", text: "streamed preview" }]);
      expect(preview.capped).toBe(false);
    } finally {
      globalThis.fetch = originalFetch;
    }
  });

  test("streams zstd data and cancels when the decompressed preview cap is reached", async () => {
    const jsonl = Array.from({ length: 4096 }, (_, index) =>
      JSON.stringify({
        role: index % 2 === 0 ? "user" : "assistant",
        content: `${index} ${randomBytes(96).toString("base64")}`,
      }),
    ).join("\n");
    const compressed = zstdCompressSync(Buffer.from(jsonl));
    let canceled = false;

    const preview = await decompressZstdPreviewStream(
      chunkedStream(compressed, 1024, () => {
        canceled = true;
      }),
      8192,
      1024 * 1024,
    );

    expect(preview.bytes.length).toBe(8192);
    expect(preview.capped).toBe(true);
    expect(canceled).toBe(true);
  });

  test("streams zstd data and stops at the compressed byte budget", async () => {
    const compressed = zstdCompressSync(randomBytes(128 * 1024));
    let canceled = false;

    const preview = await decompressZstdPreviewStream(
      chunkedStream(compressed, 1024, () => {
        canceled = true;
      }),
      8 * 1024 * 1024,
      4096,
    );

    expect(preview.capped).toBe(true);
    expect(canceled).toBe(true);
  });
});

function chunkedStream(
  bytes: Uint8Array,
  chunkSize: number,
  onCancel?: () => void,
): ReadableStream<Uint8Array> {
  let offset = 0;
  return new ReadableStream<Uint8Array>({
    pull(controller) {
      if (offset >= bytes.length) {
        controller.close();
        return;
      }
      const end = Math.min(bytes.length, offset + chunkSize);
      controller.enqueue(bytes.subarray(offset, end));
      offset = end;
    },
    cancel() {
      onCancel?.();
    },
  });
}
