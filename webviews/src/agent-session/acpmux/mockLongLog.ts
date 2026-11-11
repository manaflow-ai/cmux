// A chat with a very long history for the mock daemon (mock.ts), made on demand by seq so the mock
// never holds it: `cmuxAcpmuxMockLongLog = N` gives the first chat the page attaches N records,
// shaped like a months-old coordinator chat's log (1.57M records, 4,309 turns, ~2 KB a record):
// turns of TURN records, each a prompt, its start, tool calls and their results (a third of them a
// subagent's own), subagent progress, reply chunks and its end. A bench opens it to measure what
// opening a long chat costs (scripts/agent-pane/session-list-cpu-bench.mjs `--long`).
import type { EventRecord } from "./direct";

/// Records in one turn, as the coordinator's log averages (1.57M records / 4,309 turns).
export const LONG_LOG_TURN = 350;
const FILLER = "Reading the next file in the tree and checking what the change touched before it lands. ";

/// The kind of record `seq` (1-based) is, without making it.
export function longLogKind(seq: number, turn = LONG_LOG_TURN): { dir: "in" | "mux"; kind: string } {
  const at = (seq - 1) % turn;
  if (at === 0) return { dir: "mux", kind: "user_message" };
  if (at === 1) return { dir: "mux", kind: "turn_started" };
  if (at === turn - 1) return { dir: "mux", kind: "turn_result" };
  return {
    dir: "in",
    kind: [
      "tool_call",
      "tool_call_update",
      "agent_message_chunk",
      "subagent_progress",
      "tool_call",
      "tool_call_update",
    ][at % 6]!,
  };
}

/// The subagent that owns record `seq`, when it is a subagent's own (`_meta.acpmux.subagent`).
export function longLogOwner(target: string, seq: number, turn = LONG_LOG_TURN): string | undefined {
  const { kind } = longLogKind(seq, turn);
  const t = Math.floor((seq - 1) / turn);
  if (kind === "subagent_progress") return `${target}/toolu_sub${t}_${Math.floor(((seq - 1) % turn) / 60)}`;
  if ((kind === "tool_call" || kind === "tool_call_update") && Math.floor(((seq - 1) % turn) / 6) % 3 === 2)
    return `${target}/toolu_sub${t}_${Math.floor(((seq - 1) % turn) / 60)}`;
  return undefined;
}

/// Record `seq` of `target`'s long log, stamped as if it ran up to `end` at one record a second.
export function longLogRecord(
  target: string,
  seq: number,
  total: number,
  end: number,
  turn = LONG_LOG_TURN,
): EventRecord {
  const at = end - (total - seq) * 1000;
  const { dir, kind } = longLogKind(seq, turn);
  const t = Math.floor((seq - 1) / turn);
  if (dir === "mux") {
    const msg =
      kind === "user_message"
        ? { text: `Step ${t}: check the lanes, then land what is green. ${FILLER}`, promptId: `p-${t}` }
        : kind === "turn_result"
          ? { status: "completed" }
          : {};
    return { sessionId: target, seq, at, dir, kind, msg } as EventRecord;
  }
  const owner = longLogOwner(target, seq, turn);
  const call = `toolu_${t}_${Math.floor(((seq - 1) % turn) / 6)}`;
  const update =
    kind === "tool_call"
      ? {
          sessionUpdate: kind,
          toolCallId: call,
          title: `Read file ${seq}`,
          kind: "read",
          status: "in_progress",
          rawInput: { file_path: `/work/src/file-${seq}.ts`, note: FILLER.repeat(6) },
        }
      : kind === "tool_call_update"
        ? {
            sessionUpdate: kind,
            toolCallId: call,
            status: "completed",
            content: [{ type: "content", content: { type: "text", text: FILLER.repeat(14) } }],
          }
        : kind === "agent_message_chunk"
          ? { sessionUpdate: kind, messageId: `msg-${t}`, content: { type: "text", text: FILLER } }
          : {
              sessionUpdate: kind,
              subagentSessionId: owner,
              action: "Reading files",
              elapsedMs: seq * 10,
              tokens: seq,
              toolUses: seq % 50,
            };
  const meta =
    kind === "subagent_progress"
      ? {
          acpmux: {
            subagents: [{ id: owner, name: `Lane ${t}`, state: "running", task: "Check the lane", parent: null }],
          },
        }
      : owner
        ? { acpmux: { subagent: owner } }
        : undefined;
  return {
    sessionId: target,
    seq,
    at,
    dir,
    kind,
    msg: { method: "session/update", params: { sessionId: owner ?? target, update, ...(meta && { _meta: meta }) } },
  } as EventRecord;
}
