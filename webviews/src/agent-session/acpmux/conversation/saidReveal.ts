import type { AcpmuxRow } from "../model";

/// The `revealTurn` value that opens a chat at a message the command palette's chats page found by
/// what was said in it (acpmux `chats/text.rs`, AgentChatsPalettePage.swift `saidReveal`):
/// `said:<prompt|answer>:<the query>`. The page has no id for that message (acpmux reads the
/// harness's own transcript, the pane its replay), so it looks for the newest row of that kind whose
/// text holds every word of the query, as acpmux matched it: any case and order, within one message.
export const SAID_REVEAL = "said:";

export type SaidReveal = { answer: boolean; words: string[] };

/// Text lowercased as acpmux folds it (`chats/search.rs` `fold_char`): a final sigma (`ς`) as `σ`,
/// so a Greek word acpmux matched is found in the row too.
const fold = (text: string) => text.toLowerCase().replaceAll("ς", "σ");

/// The match a reveal names, or undefined for any other reveal.
export function revealedSaid(value: string): SaidReveal | undefined {
  if (!value.startsWith(SAID_REVEAL)) return undefined;
  const rest = value.slice(SAID_REVEAL.length);
  const colon = rest.indexOf(":");
  const role = rest.slice(0, colon);
  if (colon < 0 || (role !== "prompt" && role !== "answer")) return undefined;
  const words = [
    ...new Set(
      fold(rest.slice(colon + 1))
        .split(/\s+/)
        .filter(Boolean),
    ),
  ];
  return words.length === 0 ? undefined : { answer: role === "answer", words };
}

/// The newest row of `rows` (oldest first) that is the match's kind (the person's prompt, or the
/// agent's reply text) and holds every word. A tool call splits a reply into several rows while
/// acpmux matched the whole answer, so when no one row holds every word, the newest row holding
/// most of them stands in. Empty when none holds any (history not loaded yet).
export function saidRows(rows: readonly AcpmuxRow[], said: SaidReveal): string[] {
  const kind = said.answer ? "assistant" : "user";
  let best: { id: string; held: number } | undefined;
  for (let at = rows.length - 1; at >= 0; at--) {
    const row = rows[at]!;
    if (row.kind !== kind || !row.text) continue;
    const text = fold(row.text);
    const held = said.words.filter((word) => text.includes(word)).length;
    if (held === said.words.length) return [row.id];
    if (held > (best?.held ?? 0)) best = { id: row.id, held };
  }
  return best ? [best.id] : [];
}
