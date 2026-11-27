import type { Op, WorkStatus } from "./conversation.ts";

/**
 * The brain host's durable state ($MUX_HOME/state/host.json). The host is
 * its only writer. Each entry is a durable to-do whose effect is idempotent at
 * an owner (acpmux dedupes prompts by promptId, the conversation owner dedupes
 * ops by idempotency key), so losing a write only costs a replay. The Rust
 * core (cmux-chief state.rs) reads and writes the same JSON.
 */
export interface HostStateData {
  /** The default "mux" conversation id (from conversation-create). */
  defaultConversation?: string;
  /** The acpmux session id of the mux, and the seq of the last turn end the host settled. */
  muxSessionId?: string;
  acpmuxSeq: number;
  /**
   * Reply-key epoch, set when the core resets to a log whose turn seqs may
   * repeat keys already used (rules.ts turnKey; the rule is in core.ts acpmuxConnected).
   */
  acpmuxEpoch?: number;
  /** The mux log's identity: the `at` of its seq 1 event, once known. */
  acpmuxLog?: number;
  /** Prompts sent (or to send) to the mux whose turn has not ended: promptId -> where its reply goes. */
  prompts: Record<string, OutstandingPrompt>;
  /** Prompt ids whose turn ended (newest last, bounded): never prompted again. */
  answered: string[];
  /** Conversation ops not yet confirmed by the owner, in order (flushed on every daemon connect). */
  outbox: OutboxEntry[];
  /** Child agents: acpmux session id -> its work-part message. */
  children: Record<string, ChildRecord>;
  /** Children pruned past MAX_CHILDREN, oldest first (at most MAX_PRUNED): one that comes back gets no second card. */
  prunedChildren?: string[];
}

export interface OutstandingPrompt {
  conversation: string;
  text: string;
  /** The human message it answers (inbox prompts only). */
  seq?: number;
  /** When it was recorded, among outstanding prompts (resend order; absent reads as 0, ties by id). */
  order?: number;
}

export interface OutboxEntry {
  conversation: string;
  idempotency_key: string;
  /** Set after one retry of an `agent_rate` reject. */
  rateRetried?: boolean;
  /** Not sent before this time (ms since the epoch); set with `rateRetried`. */
  notBefore?: number;
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
  /** When it was recorded, among children (prune order; absent reads as 0, ties by id). */
  order?: number;
}

/** Most children host.json keeps; past it the oldest finished child with no queued op is pruned. */
export const MAX_CHILDREN = 100;
/** Most pruned child ids host.json remembers. */
export const MAX_PRUNED = 1_000;

/** Most answered prompt ids kept. */
export const MAX_ANSWERED = 2_000;

/** A state with defaults for every missing field (a missing or partial host.json). */
export function loadState(loaded: Partial<HostStateData> = {}): HostStateData {
  return { acpmuxSeq: 0, prompts: {}, answered: [], outbox: [], children: {}, ...loaded };
}

/** A deep copy with no undefined fields: what `persist` carries and host.json holds. */
export function plainState(state: HostStateData): HostStateData {
  return JSON.parse(JSON.stringify(state)) as HostStateData;
}

export function isAnswered(state: HostStateData, promptId: string): boolean {
  return state.answered.includes(promptId);
}

/** The prompt's turn ended: it leaves the outstanding set for good. */
export function markAnswered(state: HostStateData, promptId: string): void {
  delete state.prompts[promptId];
  if (isAnswered(state, promptId)) return;
  state.answered.push(promptId);
  if (state.answered.length > MAX_ANSWERED) state.answered.splice(0, state.answered.length - MAX_ANSWERED);
}
