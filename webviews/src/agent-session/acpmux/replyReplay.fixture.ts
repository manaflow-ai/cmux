// l10n-allow-file: a synthesized chat for tests, not shipped UI.
// A background reply shaped like the one Leo saw drawn twice (2026-11-22): one assistant message whose ~50
// chunks all carry acpmux's segment stamp (`_meta.acpmux.segment`) and the message id, streamed inside a
// background turn (`background_turn` started/ended, no prompt opens it) and interleaved with many subagents'
// records (their thoughts, calls, progress). Synthesized: the real records are a coordinator's private chat.
//
// `cut` puts what came between paragraphs 1 and 2 in Leo's two chats:
// - "subagent" (images/1157.png): a subagent the pane had not seen yet sends its first records, and its new group
//   row ended the reply's row, so the rest of the message opened a second row;
// - "prompt" (images/1158.png): the person's prompt arrives, acpmux ends the background turn (reason prompt) and
//   starts the prompt's turn, and stamps the rest of the same message with a new segment (hub/stream.rs minted one
//   per turn), so it drew as a second bubble under the prompt.
import type { EventRecord } from "./direct";

export const REPLY_SESSION = "0190a000-0000-7000-8000-00000000d0b1";
export const REPLY_MESSAGE = "msg_01ReplayDuplicateText00001";
export const REPLY_SEGMENT = "-.1a2b3c4d5e6.2";
const START = 1_795_334_000_000;

/// The reply's three paragraphs, each well over the detector's 40 characters.
export const REPLY_PARAGRAPHS = [
  "The late Copy/Fork/Timeline icons under a reply are fixed in cmux#1, which is queued to merge. The icons now appear the moment a background reply ends. Before, they waited about 5.8 s.",
  "The cause was turns an agent runs on its own. When one ended, its reply kept counting as still streaming, and the icon row isn't drawn under a streaming reply.",
  "I measured it by replaying the chat log, not in the running app. One screenshot isn't explained yet: the one with only three icons. Its two likely causes haven't been checked.",
];
export const REPLY_TEXT = REPLY_PARAGRAPHS.join("\n\n");

/// Splits `text` into chunks of 4 to 30 characters, deterministically.
function chunks(text: string): string[] {
  const out: string[] = [];
  let at = 0;
  let step = 0;
  while (at < text.length) {
    const size = 4 + ((step * 7 + 3) % 27);
    out.push(text.slice(at, at + size));
    at += size;
    step += 1;
  }
  return out;
}

type Built = {
  /// Every record, oldest first: a first turn (stored when the pane opens), filler, the background reply.
  events: EventRecord[];
  /// The seqs of the reply's chunks, in order.
  chunkSeqs: number[];
  /// The seq of the first chunk of the second paragraph (where Leo's second copy began).
  secondParagraphSeq: number;
  /// The background turn's start and end.
  bgStart: number;
  bgEnd: number;
  /// Index of the first record after the first turn (where live delivery starts).
  firstLive: number;
};

/// The chat: a finished first turn, `filler` subagent records (a coordinator's long running chat), then the
/// background reply with `between` subagent records after each chunk (cycling 0..between).
export type ReplyCut = "none" | "subagent" | "prompt";

export function buildReplyChat({
  filler = 40,
  between = 3,
  cut = "none",
}: { filler?: number; between?: number; cut?: ReplyCut } = {}): Built {
  const events: EventRecord[] = [];
  let seq = 0;
  let at = START;
  const push = (dir: string, kind: string, msg: Record<string, unknown>) => {
    seq += 1;
    at += 7;
    events.push({ sessionId: REPLY_SESSION, seq, at, dir, kind, msg } as EventRecord);
    return seq;
  };
  const update = (update: Record<string, unknown>, meta?: Record<string, unknown>, sessionId = REPLY_SESSION) => ({
    jsonrpc: "2.0",
    method: "session/update",
    params: { ...(meta ? { _meta: { acpmux: meta } } : {}), sessionId, update },
  });
  // The first turn: a prompt, its reply, its end.
  push("mux", "user_message", { text: "Watch the lanes.", promptId: "p1", turnId: "t1" });
  push("mux", "turn_started", { turnId: "t1", promptId: "p1" });
  push(
    "in",
    "agent_message_chunk",
    update({
      sessionUpdate: "agent_message_chunk",
      content: { type: "text", text: "Watching them now." },
      messageId: "msg_first",
    }),
  );
  push("mux", "turn_end", { turnId: "t1", stopReason: "end_turn" });
  push("mux", "turn_result", { status: "completed", promptId: "p1", turnId: "t1" });
  const firstLive = events.length;
  // Subagents running in the background: each one's records, as acpmux relays them.
  const agents = Array.from({ length: 6 }, (_, index) => `${REPLY_SESSION}/toolu_agent${index}`);
  const startAgent = (index: number) =>
    push(
      "in",
      "tool_call",
      update({
        sessionUpdate: "tool_call",
        toolCallId: `toolu_agent${index}`,
        status: "in_progress",
        kind: "think",
        title: `Lane ${index}`,
        _meta: { claude: { tool: "Agent" } },
      }),
    );
  for (let index = 0; index < agents.length; index += 1) startAgent(index);
  let call = 0;
  const subagentRecord = (index: number) => {
    const agent = agents[index % agents.length]!;
    switch (index % 4) {
      case 0:
        return push(
          "in",
          "agent_thought_chunk",
          update(
            { sessionUpdate: "agent_thought_chunk", content: { type: "text", text: `Checking item ${index}.\n\n` } },
            { subagent: agent },
            agent,
          ),
        );
      case 1:
        call += 1;
        return push(
          "in",
          "tool_call",
          update(
            {
              sessionUpdate: "tool_call",
              toolCallId: `toolu_sub${call}`,
              status: "in_progress",
              kind: "execute",
              title: `ls step-${call}`,
              rawInput: { command: `ls step-${call}` },
              _meta: { claude: { tool: "Bash" } },
            },
            { subagent: agent },
            agent,
          ),
        );
      case 2:
        return push(
          "in",
          "subagent_progress",
          update(
            {
              sessionUpdate: "subagent_progress",
              subagentSessionId: agent,
              action: "Bash",
              elapsedMs: 1000 * index,
              tokens: 100 * index,
              toolUses: index,
            },
            {
              subagents: [
                {
                  id: agent,
                  agentId: `a${index % agents.length}`,
                  name: `Lane ${index % agents.length}`,
                  state: "running",
                  background: true,
                },
              ],
            },
          ),
        );
      default:
        return push(
          "in",
          "tool_call_update",
          update(
            {
              sessionUpdate: "tool_call_update",
              toolCallId: `toolu_sub${call}`,
              status: "completed",
              content: [{ type: "content", content: { type: "text", text: `out ${call}` } }],
            },
            { subagent: agent },
            agent,
          ),
        );
    }
  };
  for (let index = 0; index < filler; index += 1) subagentRecord(index);
  const bgStart = push("mux", "background_turn", {
    id: "bg-1",
    state: "started",
    trigger: "task_notification",
    cause: {
      kind: "unknown",
      origin: "toolu_agent0",
      status: "completed",
      summary: "Lane 0 finished.",
      weight: "result",
    },
  });
  const chunkSeqs: number[] = [];
  let secondParagraphSeq = 0;
  let written = "";
  let extra = 0;
  let segment = REPLY_SEGMENT;
  const cutHere = () => {
    if (cut === "subagent") {
      // A subagent never seen before: its first thought and its progress make a new group row.
      const late = `${REPLY_SESSION}/toolu_agent_late`;
      push(
        "in",
        "agent_thought_chunk",
        update(
          { sessionUpdate: "agent_thought_chunk", content: { type: "text", text: "Reading the lane log." } },
          { subagent: late },
          late,
        ),
      );
      push(
        "in",
        "subagent_progress",
        update(
          {
            sessionUpdate: "subagent_progress",
            subagentSessionId: late,
            action: "Read",
            elapsedMs: 900,
            tokens: 80,
            toolUses: 1,
          },
          { subagents: [{ id: late, agentId: "a-late", name: "Late lane", state: "running", background: true }] },
        ),
      );
    } else if (cut === "prompt") {
      push("mux", "background_turn", {
        id: "bg-1",
        state: "ended",
        quiet: false,
        reason: "prompt",
        trigger: "task_notification",
      });
      push("mux", "user_message", { text: "Also check Codex.", promptId: "p2", turnId: "t2" });
      push("mux", "turn_started", { turnId: "t2", promptId: "p2" });
      segment = "t2.1a2b3c4d5e6.1";
    }
  };
  for (const text of chunks(REPLY_TEXT)) {
    if (cut !== "none" && !secondParagraphSeq && written.includes("\n\n")) cutHere();
    const at = push(
      "in",
      "agent_message_chunk",
      update(
        { sessionUpdate: "agent_message_chunk", content: { type: "text", text }, messageId: REPLY_MESSAGE },
        { segment },
      ),
    );
    if (!secondParagraphSeq && written.includes("\n\n")) secondParagraphSeq = at;
    written += text;
    chunkSeqs.push(at);
    for (let index = 0; index < extra % (between + 1); index += 1) subagentRecord(filler + extra * 3 + index);
    extra += 1;
  }
  const bgEnd =
    cut === "prompt"
      ? push("mux", "turn_end", { turnId: "t2", stopReason: "end_turn" })
      : push("mux", "background_turn", {
          id: "bg-1",
          state: "ended",
          quiet: false,
          reason: "result",
          trigger: "task_notification",
        });
  if (cut === "prompt") push("mux", "turn_result", { status: "completed", promptId: "p2", turnId: "t2" });
  for (let index = 0; index < 4; index += 1) subagentRecord(filler + 1000 + index);
  return { events, chunkSeqs, secondParagraphSeq, bgStart, bgEnd, firstLive };
}
