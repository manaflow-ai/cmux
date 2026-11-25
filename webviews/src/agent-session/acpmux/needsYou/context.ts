// Needs you's context step (Leo 2026-10-21: "maybe expand further for the context"): the last few
// turns of the asking chat before its ask, read-only, inside the row, so the person can answer
// without opening the chat. Nothing is fetched for it: this chat's turns are the rows the pane
// already holds; another chat's are what acpmux's session summary already says about it (its
// latest message), and the row says that is all it has.
import type { AcpmuxRow } from "../model";
import type { AcpmuxSessionEntry } from "../sessionList";
import type { NeedsYouItem } from "./model";

/// One turn of context: who said it and what, on at most a few lines (the CSS clamps it).
export type ContextTurn = { id: string; who: "person" | "agent"; text: string };

/// The turns before the ask, oldest first. `partial`: only the chat's latest message was known
/// (another chat), so the row points to the chat for the whole conversation.
export type AskContext = { turns: ContextTurn[]; partial: boolean };

/// How many turns the step shows: enough for the exchange that led to the ask, never a transcript.
export const CONTEXT_TURNS = 4;

/// The longest a turn's text is kept (the CSS clamps what shows; this bounds what is drawn).
const MAX_TEXT = 600;

const clip = (text: string) => (text.length > MAX_TEXT ? `${text.slice(0, MAX_TEXT - 1)}…` : text);

export function askContext(
  item: NeedsYouItem,
  open: { sessionId?: string; rows: readonly AcpmuxRow[] },
  sessions: readonly AcpmuxSessionEntry[],
): AskContext {
  if (item.sessionId === open.sessionId) return { turns: turnsBefore(open.rows, item.turnId), partial: false };
  const session = sessions.find((each) => each.sessionId === item.sessionId);
  const latest = (session?.lastMessage ?? session?.preview)?.trim();
  return {
    turns: latest ? [{ id: `latest:${item.sessionId}`, who: "agent", text: clip(latest) }] : [],
    partial: true,
  };
}

/// The person's prompts and the agent's replies up to the end of turn `turnId` (the ask's turn;
/// every row when it is unknown or not loaded), the last ``CONTEXT_TURNS`` of them. Tool rows,
/// notes and other agents' messages are left out: the step shows the conversation, not its work.
export function turnsBefore(rows: readonly AcpmuxRow[], turnId?: string): ContextTurn[] {
  let end = rows.length;
  if (turnId) {
    let last = rows.length - 1;
    while (last >= 0 && rows[last]!.turnId !== turnId) last--;
    if (last >= 0) end = last + 1;
  }
  const turns: ContextTurn[] = [];
  for (let index = end - 1; index >= 0 && turns.length < CONTEXT_TURNS; index--) {
    const row = rows[index]!;
    const text = row.text?.trim();
    if (!text || row.incoming) continue;
    if (row.kind === "user") turns.push({ id: row.id, who: "person", text: clip(text) });
    else if (row.kind === "assistant") turns.push({ id: row.id, who: "agent", text: clip(text) });
  }
  return turns.reverse();
}
