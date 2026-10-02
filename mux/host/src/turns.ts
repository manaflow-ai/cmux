import type { AcpmuxEvent } from "./acpmux-client.ts";

// Folds one acpmux session's event log into turns. acpmux records, per turn:
// `user_message {promptId}` (dir mux), `turn_started` (its seq is the turn's
// id), agent output as `agent_message_chunk` updates, then `turn_end` or
// `turn_error`. Replayed (attach) and live events fold the same way; events
// at or below the last folded seq are ignored. Pure: no I/O.

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
      const promptId = typeof event.msg.promptId === "string" ? event.msg.promptId : undefined;
      // A steered prompt joins the running turn; any other starts the next one.
      if (event.msg.steer !== true || !this.current) this.lastPromptId = promptId;
      if (promptId) out.push({ type: "accepted", promptId, seq: event.seq });
    } else if (event.dir === "mux" && event.kind === "turn_started") {
      this.current = { turnSeq: event.seq, promptId: this.lastPromptId, text: "" };
      this.lastPromptId = undefined;
      out.push({ type: "started", turn: { ...this.current }, seq: event.seq });
    } else if (event.kind === "agent_message_chunk") {
      const update = (event.msg.params as { update?: { content?: { type?: string; text?: string } } } | undefined)
        ?.update;
      if (this.current && update?.content?.type === "text" && update.content.text)
        this.current.text += update.content.text;
    } else if (event.dir === "mux" && (event.kind === "turn_end" || event.kind === "turn_error")) {
      if (this.current) {
        const error =
          event.kind === "turn_error" ? String(event.msg.error ?? JSON.stringify(event.msg)).slice(0, 300) : undefined;
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
