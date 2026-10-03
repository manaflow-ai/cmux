// The acpmux shapes the core reads (the `_acpmux/*` wire, camelCase) and the
// turn folder: one acpmux session's event log folded into turns. acpmux
// records, per turn: `user_message {promptId}` (dir mux), `turn_started` (its
// seq is the turn's id), agent output as `agent_message_chunk` updates, then
// `turn_end` or `turn_error`. Replayed (attach) and live events fold the same
// way; events at or below the last folded seq are ignored. Pure: no I/O.

import { canonicalJson } from "./text.ts";

export type SessionStatus = "idle" | "ready" | "running" | "waiting" | "disconnected" | "closed";

/** `_acpmux/session_changed` and `_acpmux/sessions` rows. */
export interface SessionSummary {
  sessionId: string;
  name: string;
  harness: string;
  cwd: string;
  status: SessionStatus;
  pendingPermissions: number;
  stateSeq: number;
  lastSeq?: number;
  turnCount?: number;
  preview: string | null;
  lastPrompt?: string | null;
  tags: Record<string, string>;
}

/** One recorded acpmux event (`_acpmux/event`, attach replays, `_acpmux/events`). */
export interface AcpmuxEvent {
  sessionId?: string;
  seq: number;
  at?: number;
  dir: string;
  kind: string;
  msg: Record<string, unknown>;
}

export interface Turn {
  /** The seq of the `turn_started` event: unique within the acpmux session. */
  turnSeq: number;
  /** The promptId of the prompt that started the turn (undefined if acpmux recorded none). */
  promptId?: string;
  text: string;
}

export type TurnOutput =
  | { type: "accepted"; promptId: string; seq: number }
  | { type: "started"; turn: Turn; seq: number }
  | { type: "ended"; turn: Turn; seq: number; error?: string };

/** Longest turn error kept in a reply, in UTF-16 units. */
const ERROR_UNITS = 300;

/**
 * The first `limit` UTF-16 units of `text` (JavaScript `slice(0, limit)`),
 * except that a surrogate pair is never split: a lone surrogate is not valid
 * on every wire (the Rust core cannot hold one), so the cut drops the whole
 * character.
 */
export function utf16Prefix(text: string, limit: number): string {
  if (text.length <= limit) return text;
  let end = limit;
  const last = text.charCodeAt(end - 1);
  if (end > 0 && last >= 0xd800 && last <= 0xdbff) end -= 1;
  return text.slice(0, end);
}

/** A prompt id from an event: a non-empty string, else none. */
function promptIdOf(msg: Record<string, unknown>): string | undefined {
  return typeof msg.promptId === "string" && msg.promptId !== "" ? msg.promptId : undefined;
}

export class TurnFolder {
  private lastSeq: number;
  private current?: Turn;
  private lastPromptId?: string;

  constructor(afterSeq = 0) {
    this.lastSeq = afterSeq;
  }

  get seq(): number {
    return this.lastSeq;
  }

  get running(): Turn | undefined {
    return this.current;
  }

  apply(event: AcpmuxEvent): TurnOutput[] {
    if (event.seq > 0) {
      if (event.seq <= this.lastSeq) return [];
      this.lastSeq = event.seq;
    }
    const out: TurnOutput[] = [];
    if (event.dir === "mux" && event.kind === "user_message") {
      const promptId = promptIdOf(event.msg);
      // A steered prompt joins the running turn; any other starts the next one.
      if (event.msg.steer !== true || !this.current) this.lastPromptId = promptId;
      if (promptId) out.push({ type: "accepted", promptId, seq: event.seq });
    } else if (event.dir === "mux" && event.kind === "queued") {
      // Queued behind the running turn: acpmux holds it, so it is accepted.
      const promptId = promptIdOf(event.msg);
      if (promptId) out.push({ type: "accepted", promptId, seq: event.seq });
    } else if (event.dir === "mux" && event.kind === "turn_started") {
      this.current = { turnSeq: event.seq, promptId: this.lastPromptId, text: "" };
      this.lastPromptId = undefined;
      out.push({ type: "started", turn: { ...this.current }, seq: event.seq });
    } else if (event.kind === "agent_message_chunk") {
      const update = (event.msg.params as { update?: { content?: { type?: unknown; text?: unknown } } } | undefined)
        ?.update;
      // Only string text counts; anything else in `text` is skipped.
      const text = update?.content?.type === "text" ? update.content.text : undefined;
      if (this.current && typeof text === "string") this.current.text += text;
    } else if (event.dir === "mux" && (event.kind === "turn_end" || event.kind === "turn_error")) {
      if (this.current) {
        const error =
          event.kind === "turn_error"
            ? utf16Prefix(String(event.msg.error ?? canonicalJson(event.msg)), ERROR_UNITS)
            : undefined;
        out.push({ type: "ended", turn: this.current, seq: event.seq, ...(error ? { error } : {}) });
        this.current = undefined;
      }
    }
    return out;
  }
}

/** The text of the last turn that ended in an event list (a child's last reply). */
export function lastReply(events: AcpmuxEvent[]): string {
  const folder = new TurnFolder();
  let reply = "";
  for (const event of events)
    for (const output of folder.apply(event)) if (output.type === "ended") reply = output.turn.text.trim();
  return reply;
}
