// Messages from other sessions (#21604): the cmux-tui pump sends each as a prompt carrying
// `_meta.provenance.kind: "agent_message"` (acpmux prompt_provenance.rs, cx-55d27), its text the
// envelope cmux-tui's agent_message_prompt.rs renders around the sender's words. The pane draws it
// as "Received message from <sender>" (ReceivedMessage.tsx); several in a row fold into one
// "Received N messages" line.
import type { AcpmuxAgentMessage, AcpmuxRow } from "../model";

/// The row kind of a message waiting behind a busy turn: its received line, drawn before the
/// prompt itself lands (direct.ts `queued`).
export const RECEIVED_MESSAGE = "receivedMessage";
/// The row kind of received lines folded together.
export const RECEIVED_GROUP = "receivedGroup";

/// The message another session sent, from a `user_message` or `queued` record; undefined for
/// any other prompt.
export function agentMessage(msg: any): AcpmuxAgentMessage | undefined {
  const provenance = msg?._meta?.provenance;
  if (provenance?.kind !== "agent_message" || typeof provenance.msgId !== "string") return undefined;
  const from = typeof provenance.from === "string" ? provenance.from : "";
  const name = typeof provenance.fromName === "string" && provenance.fromName.trim() ? provenance.fromName : from;
  const sessionId = from.startsWith("acp:") ? from.slice(4) : undefined;
  return {
    msgId: provenance.msgId,
    title: name || from,
    ...(sessionId ? { sessionId } : {}),
    body: messageBody(String(msg.text ?? ""), provenance.msgId),
  };
}

/// The sender's words inside the envelope: after its first `---` line, before the closing line
/// that repeats the message id (which a body cannot fake). Text in any other shape is kept whole.
function messageBody(text: string, msgId: string): string {
  const start = text.indexOf("\n---\n");
  const end = text.lastIndexOf(`\n--- end of message ${msgId} ---`);
  return (start >= 0 && end > start ? text.slice(start + 5, end) : text).trim();
}

/// The message a row draws as a received line, if it is one.
export const receivedMessage = (row: AcpmuxRow): AcpmuxAgentMessage | undefined =>
  (row.kind === "user" || row.kind === RECEIVED_MESSAGE) && row.message ? row.message : undefined;

/// `rows` with each run of two or more received lines folded into one "Received N messages" row,
/// whose id is in `expanded` while its lines show under it.
export function groupReceived(rows: readonly AcpmuxRow[], expanded: ReadonlySet<string>): AcpmuxRow[] {
  const out: AcpmuxRow[] = [];
  let folded = false;
  for (let index = 0; index < rows.length;) {
    let end = index;
    while (end < rows.length && receivedMessage(rows[end]!)) end++;
    if (end - index < 2) {
      out.push(rows[index]!);
      index = Math.max(end, index + 1);
      continue;
    }
    folded = true;
    const run = rows.slice(index, end);
    const id = `${RECEIVED_GROUP}-${run[0]!.id}`;
    const open = expanded.has(id);
    out.push({
      id,
      kind: RECEIVED_GROUP,
      // Redraws when a line joins or the group opens.
      version: run.length * 2 + (open ? 1 : 0),
      at: run[0]!.at,
      count: run.length,
    });
    if (open) out.push(...run);
    index = end;
  }
  // Nothing folded: the rows as they came, so a list without received runs keeps its identity.
  return folded ? out : (rows as AcpmuxRow[]);
}
