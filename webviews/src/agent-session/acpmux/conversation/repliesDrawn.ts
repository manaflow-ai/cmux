// What the agent said last in each turn it ended, read from the acpmux log, and whether the chat
// draws it (Leo, 2026-11-12: "I can't see the GUI coordinator talking to me right now ... you should
// be able to detect that the messages aren't coming out from the coordinator"). The log is the
// truth; the drawn rows are the transcript's own reducer (direct.ts) and fold (turns.ts).
import type { EventRecord } from "../direct";
import type { AcpmuxRow } from "../model";

/// A turn the agent ended with something to read: its final reply as the log has it.
export type TurnReply = {
  turnId: string;
  /// The turn's `turn_started` and `turn_end` records.
  startSeq: number;
  endSeq: number;
  /// The reply segment's first and last chunk.
  fromSeq: number;
  toSeq: number;
  /// The segment key the row is drawn under (`_meta.acpmux.segment`, else the message id).
  segment: string;
  text: string;
};

const updateOf = (event: EventRecord): any => event.msg?.params?.update;

/// Each turn that ended normally (`end_turn`), with its last reply: the last text segment begun after its last tool call. A turn
/// whose text all came before more work has no final reply here (its notes fold by design).
export function turnReplies(events: readonly EventRecord[]): TurnReply[] {
  const out: TurnReply[] = [];
  let open: { turnId: string; startSeq: number; segments: Map<string, { from: number; to: number; text: string }>; lastCall: number } | undefined;
  for (const event of events) {
    if (event.dir === "mux" && event.kind === "turn_started") {
      open = { turnId: String(event.msg?.turnId ?? event.seq), startSeq: event.seq, segments: new Map(), lastCall: -1 };
      continue;
    }
    if (!open) continue;
    if (event.dir === "in" && (event.kind === "tool_call" || updateOf(event)?.sessionUpdate === "tool_call")) {
      if (!event.msg?.params?._meta?.acpmux?.subagent) open.lastCall = event.seq;
      continue;
    }
    if (event.dir === "in" && event.kind === "agent_message_chunk") {
      if (event.msg?.params?._meta?.acpmux?.subagent) continue;
      const update = updateOf(event);
      const text = typeof update?.content?.text === "string" ? update.content.text : "";
      const key = String(event.msg?.params?._meta?.acpmux?.segment ?? update?.messageId ?? `seq-${event.seq}`);
      const seen = open.segments.get(key);
      if (seen) {
        seen.text += text;
        seen.to = event.seq;
      } else open.segments.set(key, { from: event.seq, to: event.seq, text });
      continue;
    }
    // A page the pane reads holds `turn_result` only (acpmux paging.rs leaves `turn_end` out).
    if (event.dir === "mux" && (event.kind === "turn_end" || event.kind === "turn_result")) {
      if (event.msg?.stopReason === "end_turn" || (event.kind === "turn_result" && event.msg?.status === "completed")) {
        let last: [string, { from: number; to: number; text: string }] | undefined;
        for (const entry of open.segments) if (entry[1].text.trim() && entry[1].from > open.lastCall) last = entry;
        if (last)
          out.push({
            turnId: open.turnId,
            startSeq: open.startSeq,
            endSeq: event.seq,
            fromSeq: last[1].from,
            toSeq: last[1].to,
            segment: last[0],
            text: last[1].text,
          });
      }
      open = undefined;
    }
  }
  return out;
}

/// The replies among `replies` that `drawn` (the chat's rows as drawn, folds closed) does not show
/// as a row of their own: missing, empty, cut short, or held inside a closed fold.
export function undrawnReplies(replies: readonly TurnReply[], drawn: readonly AcpmuxRow[]): TurnReply[] {
  const shown = new Map<string, string>();
  for (const row of drawn)
    if (row.kind === "assistant" && !row.foldedReply && typeof row.text === "string")
      shown.set(row.id, (shown.get(row.id) ?? "") + row.text);
  const texts = new Set([...shown.values()].map((text) => text.trim()));
  return replies.filter((reply) => {
    const own = shown.get(`assistant-${reply.segment}`);
    if (own !== undefined) return own.trim() !== reply.text.trim();
    return !texts.has(reply.text.trim());
  });
}
