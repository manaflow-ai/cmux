"use client";

import { useCallback, useMemo, useRef, useState } from "react";
import { Decompress } from "fzstd";
import { useVirtualizer } from "@tanstack/react-virtual";
import { useTranslations } from "next-intl";
import {
  TranscriptLineParser,
  type TranscriptMessage,
} from "@/services/vault/transcript";

const FLUSH_MESSAGE_COUNT = 500;
const MAX_DECOMPRESSED_BYTES = 256 * 1024 * 1024;
const STOP_TRANSCRIPT_STREAM = Symbol("stop-transcript-stream");

type StreamStatus = "idle" | "loading" | "done" | "error" | "too-large";

export function TranscriptViewer({
  sessionId,
  initialMessages,
  complete,
}: {
  readonly sessionId: string;
  readonly initialMessages: readonly TranscriptMessage[];
  readonly complete: boolean;
}) {
  const t = useTranslations("vault.detail");
  // Messages are stored as append-only chunks so each streaming flush copies
  // only the (small) chunk list instead of every previously loaded message;
  // a flat array made large transcript streaming O(n) per flush.
  const [chunks, setChunks] = useState<readonly (readonly TranscriptMessage[])[]>([
    initialMessages,
  ]);
  const [status, setStatus] = useState<StreamStatus>(
    complete ? "done" : "loading",
  );
  const { messageCount, chunkStarts } = useMemo(() => {
    const starts: number[] = new Array(chunks.length);
    let total = 0;
    for (let i = 0; i < chunks.length; i++) {
      starts[i] = total;
      total += chunks[i].length;
    }
    return { messageCount: total, chunkStarts: starts };
  }, [chunks]);
  const messageAt = useCallback(
    (index: number): TranscriptMessage | undefined => {
      // Binary search for the chunk containing index.
      let lo = 0;
      let hi = chunkStarts.length - 1;
      while (lo < hi) {
        const mid = (lo + hi + 1) >> 1;
        if (chunkStarts[mid] <= index) lo = mid;
        else hi = mid - 1;
      }
      return chunks[lo]?.[index - chunkStarts[lo]];
    },
    [chunks, chunkStarts],
  );
  const [scrollElement, setScrollElement] = useState<HTMLDivElement | null>(null);
  const startedRef = useRef(complete);
  const initialMessageCountRef = useRef(initialMessages.length);
  const abortRef = useRef<AbortController | null>(null);

  const rowVirtualizer = useVirtualizer({
    count: messageCount,
    getScrollElement: () => scrollElement,
    estimateSize: () => 96,
    initialRect: { width: 768, height: 720 },
    overscan: 8,
  });

  const loadTranscript = useCallback(async () => {
    const controller = new AbortController();
    abortRef.current = controller;
    // A restarted run (dev StrictMode replays the callback ref) must not
    // append after a partially-flushed aborted run: reset to the server batch.
    setChunks([initialMessages]);
    setStatus("loading");

    const pendingMessages: TranscriptMessage[] = [];
    const flushMessages = () => {
      if (pendingMessages.length === 0) return;
      const batch = pendingMessages.splice(0);
      setChunks((current) => [...current, batch]);
    };

    let parsedMessageCount = 0;
    const parser = new TranscriptLineParser((message) => {
      parsedMessageCount += 1;
      if (parsedMessageCount <= initialMessageCountRef.current) return;
      pendingMessages.push(message);
      if (pendingMessages.length >= FLUSH_MESSAGE_COUNT) flushMessages();
    });
    const decoder = new TextDecoder();
    let decompressedBytes = 0;
    let stoppedTooLarge = false;

    try {
      const response = await fetch(`/api/vault/sessions/${sessionId}/content`, {
        cache: "no-store",
        signal: controller.signal,
      });
      if (!response.ok || !response.body) throw new Error("transcript_fetch_failed");

      const reader = response.body.getReader();
      const decompressor = new Decompress((chunk) => {
        const remainingBytes = MAX_DECOMPRESSED_BYTES - decompressedBytes;
        if (remainingBytes <= 0) {
          stoppedTooLarge = true;
          throw STOP_TRANSCRIPT_STREAM;
        }

        const usableChunk =
          chunk.length > remainingBytes ? chunk.subarray(0, remainingBytes) : chunk;
        decompressedBytes += usableChunk.length;
        parser.feed(decoder.decode(usableChunk, { stream: true }));

        if (chunk.length > remainingBytes) {
          stoppedTooLarge = true;
          throw STOP_TRANSCRIPT_STREAM;
        }
      });

      try {
        while (true) {
          const { done, value } = await reader.read();
          if (done) break;
          try {
            decompressor.push(value, false);
          } catch (error) {
            if (error !== STOP_TRANSCRIPT_STREAM) throw error;
            stoppedTooLarge = true;
            controller.abort();
            await cancelReader(reader);
            break;
          }
        }

        if (!stoppedTooLarge) {
          try {
            decompressor.push(new Uint8Array(), true);
          } catch (error) {
            if (error !== STOP_TRANSCRIPT_STREAM) throw error;
            stoppedTooLarge = true;
          }
        }
      } finally {
        reader.releaseLock();
      }

      const decodedTail = decoder.decode();
      if (decodedTail) parser.feed(decodedTail);
      parser.finish();
      flushMessages();
      setStatus(stoppedTooLarge ? "too-large" : "done");
    } catch (error) {
      if (controller.signal.aborted && !stoppedTooLarge) return;
      if (error !== STOP_TRANSCRIPT_STREAM) {
        flushMessages();
        setStatus("error");
        return;
      }
      parser.finish();
      flushMessages();
      setStatus("too-large");
    } finally {
      if (abortRef.current === controller) abortRef.current = null;
    }
  }, [sessionId, initialMessages]);

  const attachScrollElement = useCallback(
    (node: HTMLDivElement | null) => {
      setScrollElement(node);
      if (!node) {
        abortRef.current?.abort();
        // React 19 StrictMode replays refs (attach, detach, attach); allow the
        // re-attach to restart the aborted load.
        startedRef.current = complete;
        return;
      }
      if (complete || startedRef.current) return;
      startedRef.current = true;
      void loadTranscript();
    },
    [complete, loadTranscript],
  );

  const statusLine = statusText(status, messageCount, t);
  const virtualItems = rowVirtualizer.getVirtualItems();

  return (
    <section ref={attachScrollElement} className="h-full overflow-y-auto">
      <div className="max-w-3xl px-4 pb-16 pt-14">
        <p className="mb-3 text-xs text-muted">{statusLine}</p>
        {status === "done" && messageCount === 0 ? (
          <p className="text-xs text-muted">{t("emptyTranscript")}</p>
        ) : null}
        <div
          className="relative border-y border-border"
          style={{ height: `${rowVirtualizer.getTotalSize()}px` }}
        >
          {virtualItems.map((virtualRow) => {
            const message = messageAt(virtualRow.index);
            if (!message) return null;
            return (
              <div
                key={virtualRow.key}
                ref={rowVirtualizer.measureElement}
                data-index={virtualRow.index}
                className="absolute left-0 top-0 grid w-full gap-2 border-b border-border py-3 md:grid-cols-[110px_minmax(0,1fr)]"
                style={{
                  transform: `translateY(${virtualRow.start}px)`,
                }}
              >
                <div className="font-mono text-xs font-medium text-muted">
                  {roleLabel(message.role, t)}
                </div>
                <div className="whitespace-pre-wrap break-words">{message.text}</div>
              </div>
            );
          })}
        </div>
      </div>
    </section>
  );
}

function statusText(
  status: StreamStatus,
  count: number,
  t: (
    key:
      | "loadingMessages"
      | "loadedMessages"
      | "streamError"
      | "transcriptTooLarge",
    values: { count: number },
  ) => string,
): string {
  if (status === "done") return t("loadedMessages", { count });
  if (status === "error") return t("streamError", { count });
  if (status === "too-large") return t("transcriptTooLarge", { count });
  return t("loadingMessages", { count });
}

function roleLabel(
  role: string,
  t: (key: "roles.user" | "roles.assistant" | "roles.system" | "roles.tool") => string,
) {
  const normalized = role.toLowerCase();
  if (normalized === "user") return t("roles.user");
  if (normalized === "assistant") return t("roles.assistant");
  if (normalized === "system") return t("roles.system");
  if (normalized === "tool") return t("roles.tool");
  return normalized;
}

async function cancelReader(reader: ReadableStreamDefaultReader<Uint8Array>): Promise<void> {
  try {
    await reader.cancel();
  } catch {
    // The fetch is already being aborted; there is nothing useful to surface here.
  }
}
