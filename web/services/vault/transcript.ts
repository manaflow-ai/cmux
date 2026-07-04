import { Decompress } from "fzstd";

export const VAULT_TRANSCRIPT_PREVIEW_MAX_BYTES = 8 * 1024 * 1024;
export const VAULT_TRANSCRIPT_PREVIEW_MAX_COMPRESSED_BYTES = 32 * 1024 * 1024;
export const VAULT_TRANSCRIPT_PREVIEW_MAX_MESSAGES = 200;

export type TranscriptMessage = {
  readonly role: string;
  readonly text: string;
};

export type TranscriptPreview = {
  readonly messages: readonly TranscriptMessage[];
  readonly capped: boolean;
  readonly messageLimitReached: boolean;
};

const PREVIEW_LIMIT = Symbol("preview-limit");

export async function fetchTranscriptPreview(url: string): Promise<TranscriptPreview> {
  const response = await fetch(url, { cache: "no-store" });
  if (!response.ok) throw new Error("transcript_fetch_failed");
  const decompressed = await decompressZstdPreviewStream(
    response.body,
    VAULT_TRANSCRIPT_PREVIEW_MAX_BYTES,
    VAULT_TRANSCRIPT_PREVIEW_MAX_COMPRESSED_BYTES,
  );
  const text = new TextDecoder().decode(decompressed.bytes);
  return extractTranscriptMessages(text, {
    maxMessages: VAULT_TRANSCRIPT_PREVIEW_MAX_MESSAGES,
    capped: decompressed.capped,
  });
}

export function decompressZstdPreview(
  compressed: Uint8Array,
  maxBytes: number,
): { readonly bytes: Uint8Array; readonly capped: boolean } {
  const accumulator = createPreviewAccumulator(maxBytes);
  const decompressor = new Decompress((chunk) => accumulator.append(chunk));

  try {
    decompressor.push(compressed, true);
  } catch (error) {
    if (error !== PREVIEW_LIMIT) throw error;
  }

  return { bytes: accumulator.finish(), capped: accumulator.capped };
}

export async function decompressZstdPreviewStream(
  stream: ReadableStream<Uint8Array> | null,
  maxBytes: number,
  maxCompressedBytes: number,
): Promise<{ readonly bytes: Uint8Array; readonly capped: boolean }> {
  if (!stream) throw new Error("transcript_body_unavailable");
  if (maxBytes <= 0 || maxCompressedBytes <= 0) return { bytes: new Uint8Array(), capped: true };

  const reader = stream.getReader();
  const accumulator = createPreviewAccumulator(maxBytes);
  const decompressor = new Decompress((chunk) => accumulator.append(chunk));
  let compressedBytes = 0;
  let capped = false;
  let fullyRead = false;

  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) {
        fullyRead = true;
        break;
      }
      if (!value || value.length === 0) continue;

      const remainingCompressedBytes = maxCompressedBytes - compressedBytes;
      if (remainingCompressedBytes <= 0) {
        capped = true;
        await cancelReader(reader);
        break;
      }

      const reachesCompressedCap = value.length >= remainingCompressedBytes;
      const chunk = reachesCompressedCap ? value.subarray(0, remainingCompressedBytes) : value;
      compressedBytes += chunk.length;

      try {
        if (chunk.length > 0) decompressor.push(chunk, false);
      } catch (error) {
        if (error !== PREVIEW_LIMIT) throw error;
        capped = true;
        await cancelReader(reader);
        break;
      }

      if (reachesCompressedCap) {
        capped = true;
        await cancelReader(reader);
        break;
      }
    }

    if (fullyRead && !capped) {
      try {
        decompressor.push(new Uint8Array(), true);
      } catch (error) {
        if (error !== PREVIEW_LIMIT) throw error;
        capped = true;
      }
    }
  } finally {
    reader.releaseLock();
  }

  return { bytes: accumulator.finish(), capped: capped || accumulator.capped };
}

function createPreviewAccumulator(maxBytes: number): {
  readonly capped: boolean;
  readonly append: (chunk: Uint8Array) => void;
  readonly finish: () => Uint8Array;
} {
  const chunks: Uint8Array[] = [];
  let total = 0;
  let capped = false;

  return {
    get capped() {
      return capped;
    },
    append(chunk) {
      if (total >= maxBytes) {
        capped = true;
        throw PREVIEW_LIMIT;
      }
      const remaining = maxBytes - total;
      if (chunk.length > remaining) {
        chunks.push(chunk.slice(0, remaining));
        total = maxBytes;
        capped = true;
        throw PREVIEW_LIMIT;
      }
      if (chunk.length > 0) {
        chunks.push(chunk.slice());
        total += chunk.length;
      }
    },
    finish() {
      return concatChunks(chunks, total);
    },
  };
}

function concatChunks(chunks: readonly Uint8Array[], total: number): Uint8Array {
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.length;
  }
  return bytes;
}

async function cancelReader(reader: ReadableStreamDefaultReader<Uint8Array>): Promise<void> {
  try {
    await reader.cancel();
  } catch {
    // The stream may already be closed or errored; the preview is already bounded.
  }
}

export function extractTranscriptMessages(
  jsonl: string,
  options: {
    readonly maxMessages?: number;
    readonly capped?: boolean;
  } = {},
): TranscriptPreview {
  const maxMessages = options.maxMessages ?? VAULT_TRANSCRIPT_PREVIEW_MAX_MESSAGES;
  const messages: TranscriptMessage[] = [];
  let messageLimitReached = false;

  for (const line of jsonl.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    let parsed: unknown;
    try {
      parsed = JSON.parse(trimmed);
    } catch {
      continue;
    }

    const message = extractMessage(parsed);
    if (!message) continue;
    messages.push(message);
    if (messages.length >= maxMessages) {
      messageLimitReached = true;
      break;
    }
  }

  return {
    messages,
    capped: options.capped ?? false,
    messageLimitReached,
  };
}

function extractMessage(value: unknown): TranscriptMessage | null {
  for (const candidate of messageCandidates(value)) {
    const role = stringProperty(candidate, "role");
    if (!role) continue;
    const text = extractText(candidate);
    if (!text) continue;
    return { role, text };
  }
  return null;
}

function messageCandidates(value: unknown): readonly Record<string, unknown>[] {
  if (!isRecord(value)) return [];
  const candidates: Record<string, unknown>[] = [value];
  if (isRecord(value.message)) candidates.push(value.message);
  if (isRecord(value.payload)) candidates.push(value.payload);
  return candidates;
}

function extractText(record: Record<string, unknown>): string | null {
  const directText = stringProperty(record, "text");
  if (directText) return directText;
  const content = record.content;
  if (typeof content === "string" && content.trim()) return content;
  if (Array.isArray(content)) {
    const parts = content
      .map((item) => (isRecord(item) && typeof item.text === "string" ? item.text : null))
      .filter((text): text is string => Boolean(text?.trim()));
    if (parts.length > 0) return parts.join("\n");
  }
  return null;
}

function stringProperty(record: Record<string, unknown>, key: string): string | null {
  const value = record[key];
  return typeof value === "string" && value.trim() ? value : null;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}
