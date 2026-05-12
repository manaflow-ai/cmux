/**
 * Transcript: append-only JSONL log of session events.
 */

import type { Message, SessionMeta, StreamEvent } from "./types.js";
import { existsSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";

// ----------------------------------------------------------------------------
// Event union
// ----------------------------------------------------------------------------

export type TranscriptEvent =
  | { kind: "session_start"; meta: SessionMeta; ts: string }
  | { kind: "message"; message: Message; ts: string }
  | { kind: "tool_call_pre"; toolName: string; input: unknown; toolUseId: string; ts: string }
  | { kind: "tool_call_post"; toolUseId: string; result: unknown; isError: boolean; ts: string }
  | { kind: "stream_event"; event: StreamEvent; ts: string }
  | { kind: "abort"; reason: string; ts: string }
  | { kind: "error"; error: { message: string; stack?: string }; ts: string }
  | { kind: "custom"; name: string; data: unknown; ts: string };

// ----------------------------------------------------------------------------
// Transcript class
// ----------------------------------------------------------------------------

export class Transcript {
  private _writer: ReturnType<ReturnType<typeof Bun.file>["writer"]> | null = null;

  constructor(readonly path: string) {
    const dir = dirname(path);
    if (!existsSync(dir)) {
      mkdirSync(dir, { recursive: true });
    }
  }

  /** Lazily open (or reuse) a file writer in append mode. */
  private writer(): ReturnType<ReturnType<typeof Bun.file>["writer"]> {
    if (!this._writer) {
      this._writer = Bun.file(this.path).writer({ flags: "a" } as never);
    }
    return this._writer;
  }

  /** Append a single event as a JSON line and flush. */
  async append(event: TranscriptEvent): Promise<void> {
    const line = JSON.stringify(event) + "\n";
    const w = this.writer();
    w.write(line);
    await w.flush();
  }

  /** Read all events from disk. Corrupt/partial trailing lines are skipped with a warning. */
  async load(): Promise<TranscriptEvent[]> {
    const file = Bun.file(this.path);
    const exists = await file.exists();
    if (!exists) return [];

    const text = await file.text();
    const events: TranscriptEvent[] = [];
    const lines = text.split("\n");
    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed) continue;
      try {
        events.push(JSON.parse(trimmed) as TranscriptEvent);
      } catch {
        console.warn(`[Transcript] Skipping corrupt line in ${this.path}: ${trimmed.slice(0, 80)}`);
      }
    }
    return events;
  }

  /** Derived view: only the message events, in order. */
  async messages(): Promise<Message[]> {
    const events = await this.load();
    return events
      .filter((e): e is Extract<TranscriptEvent, { kind: "message" }> => e.kind === "message")
      .map((e) => e.message);
  }
}
