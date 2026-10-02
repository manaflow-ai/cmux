import { existsSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import type { Op, WorkStatus } from "./conversation-types.ts";

/**
 * The brain host's own durable state ($MUX_HOME/state/host.json). The host is
 * its only writer. Each entry is a durable to-do whose effect is idempotent at
 * an owner (acpmux dedupes prompts by promptId, the conversation owner dedupes
 * ops by idempotency key), so losing a write only costs a replay.
 */
export interface HostStateData {
  /** The default "mux" conversation id (from conversation-create). */
  defaultConversation?: string;
  /** The acpmux session id of the mux, and the seq of the last turn end the host settled. */
  muxSessionId?: string;
  acpmuxSeq: number;
  /** Prompts sent (or to send) to the mux whose turn has not ended: promptId -> where its reply goes. */
  prompts: Record<string, OutstandingPrompt>;
  /** Conversation ops not yet confirmed by the owner, in order (flushed on every daemon connect). */
  outbox: OutboxEntry[];
  /** Child agents: acpmux session id -> its work-part message. */
  children: Record<string, ChildRecord>;
}

export interface OutstandingPrompt {
  conversation: string;
  text: string;
  /** The human message it answers (inbox prompts only). */
  seq?: number;
}

export interface OutboxEntry {
  conversation: string;
  idempotency_key: string;
  op: Op;
  /** A work-part op: its message id is filled from `children[child].messageId` when it flushes. */
  child?: string;
}

export interface ChildRecord {
  conversation: string;
  name: string;
  status: WorkStatus;
  /** The work-part message id, once the owner confirmed the send. */
  messageId?: string;
  /** How many work-part edits this child has had (each edit's idempotency key is unique). */
  edits: number;
}

export class HostState {
  data: HostStateData;

  constructor(private readonly path: string) {
    const empty: HostStateData = { acpmuxSeq: 0, prompts: {}, outbox: [], children: {} };
    let loaded: Partial<HostStateData> = {};
    if (existsSync(path)) {
      try {
        loaded = JSON.parse(readFileSync(path, "utf8")) as Partial<HostStateData>;
      } catch {
        loaded = {};
      }
    }
    this.data = { ...empty, ...loaded };
  }

  save(): void {
    const tmp = `${this.path}.${process.pid}.tmp`;
    writeFileSync(tmp, `${JSON.stringify(this.data)}\n`);
    renameSync(tmp, this.path);
  }
}
