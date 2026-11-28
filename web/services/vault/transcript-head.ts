import { Decompress } from "fzstd";
import {
  TranscriptLineParser,
  type TranscriptMessage,
} from "@/services/vault/transcript";
import { logVaultStorageError } from "@/services/vault/logging";

export const TRANSCRIPT_HEAD_MESSAGE_LIMIT = 500;
export const TRANSCRIPT_HEAD_DECOMPRESSED_BYTE_LIMIT = 2 * 1024 * 1024;

export type TranscriptHeadBatch = {
  readonly messages: readonly TranscriptMessage[];
  readonly complete: boolean;
  readonly decompressedBytes: number;
};

export type TranscriptHeadBatchOptions = {
  readonly maxMessages?: number;
  readonly maxDecompressedBytes?: number;
  readonly objectKey?: string;
};

const STOP_TRANSCRIPT_HEAD = Symbol("stop-transcript-head");

export async function fetchTranscriptHeadBatch(
  url: string,
  options: TranscriptHeadBatchOptions = {},
): Promise<TranscriptHeadBatch> {
  let response: Response;
  try {
    response = await fetch(url, { cache: "no-store" });
  } catch (error) {
    logVaultStorageError("transcript_head_fetch", options.objectKey ?? "unknown", error);
    throw error;
  }
  if (!response.ok || !response.body) {
    logVaultStorageError(
      "transcript_head_fetch",
      options.objectKey ?? "unknown",
      new Error(`transcript head fetch failed with HTTP ${response.status}`),
    );
    throw new Error("transcript_head_fetch_failed");
  }
  return readTranscriptHeadBatch(response.body, options);
}

export async function readTranscriptHeadBatch(
  stream: ReadableStream<Uint8Array>,
  options: TranscriptHeadBatchOptions = {},
): Promise<TranscriptHeadBatch> {
  const maxMessages = options.maxMessages ?? TRANSCRIPT_HEAD_MESSAGE_LIMIT;
  const maxDecompressedBytes =
    options.maxDecompressedBytes ?? TRANSCRIPT_HEAD_DECOMPRESSED_BYTE_LIMIT;
  const messages: TranscriptMessage[] = [];
  const decoder = new TextDecoder();
  let complete = true;
  let decompressedBytes = 0;

  const stop = () => {
    complete = false;
    throw STOP_TRANSCRIPT_HEAD;
  };

  const parser = new TranscriptLineParser((message) => {
    if (messages.length < maxMessages) {
      messages.push(message);
      return;
    }
    stop();
  });

  const decompressor = new Decompress((chunk) => {
    if (chunk.length === 0) return;

    const remainingBytes = maxDecompressedBytes - decompressedBytes;
    if (remainingBytes <= 0) stop();

    const usableChunk =
      chunk.length > remainingBytes ? chunk.subarray(0, remainingBytes) : chunk;
    decompressedBytes += usableChunk.length;
    parser.feed(decoder.decode(usableChunk, { stream: true }));

    if (chunk.length > remainingBytes) stop();
  });

  const reader = stream.getReader();
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      try {
        decompressor.push(value, false);
      } catch (error) {
        if (error !== STOP_TRANSCRIPT_HEAD) throw error;
        await cancelReader(reader);
        return { messages, complete, decompressedBytes };
      }
    }

    try {
      decompressor.push(new Uint8Array(), true);
      const decodedTail = decoder.decode();
      if (decodedTail) parser.feed(decodedTail);
      parser.finish();
    } catch (error) {
      if (error !== STOP_TRANSCRIPT_HEAD) throw error;
      return { messages, complete, decompressedBytes };
    }

    return { messages, complete, decompressedBytes };
  } finally {
    reader.releaseLock();
  }
}

async function cancelReader(
  reader: ReadableStreamDefaultReader<Uint8Array>,
): Promise<void> {
  try {
    await reader.cancel();
  } catch {
    // The caller is intentionally stopping early after a bounded head batch.
  }
}
