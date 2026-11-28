// A prompt whose send timed out (`native.timed_out`, no answer) goes back to the composer as not
// sent, but acpmux may have taken it all the same: its `queued` or `user_message` record then comes
// late. Without this, the composer still held the words, and the person's next send carried them
// again (Leo, 2026-11-25: "that message got split up and queued"; the same words arrived two and
// three times, once joined to later messages). When the record comes, the copy handed back is taken
// out of the composer again, if it is still there: acpmux has the prompt, the composer must not.

import type { ComposerAttachment } from "./attachments";

export type HandedBack = { text: string; attachments: ComposerAttachment[] };

const waiting = new Map<string, HandedBack>();
const listeners = new Set<(back: HandedBack) => void>();
// The prompts acpmux recorded lately, by id: a copy about to be handed back after its record came
// (a held prompt the host's journal resent while its sender gave it up) is never handed back.
const recorded = new Set<string>();

/// Prompt `promptId` went back to the composer although acpmux may have it.
export function noteHandedBack(promptId: string, back: HandedBack): void {
  waiting.set(promptId, back);
  // Bounded: a prompt acpmux never took leaves its entry only until the page's next dozen.
  while (waiting.size > 32) waiting.delete(waiting.keys().next().value as string);
}

/// acpmux recorded prompt `promptId`: whoever holds a handed-back copy of it lets go.
export function promptRecorded(promptId: string): void {
  recorded.delete(promptId);
  recorded.add(promptId);
  // Bounded: the page's last few hundred prompts are the ones a late give-back can be about.
  while (recorded.size > 512) recorded.delete(recorded.values().next().value as string);
  const back = waiting.get(promptId);
  if (!back) return;
  waiting.delete(promptId);
  for (const listener of listeners) listener(back);
}

/// Whether acpmux recorded prompt `promptId` already: its copy must not go back into a composer or
/// a draft, where the next Send would carry it again.
export function wasRecorded(promptId: string): boolean {
  return recorded.has(promptId);
}

export function onHandedBackRecorded(listener: (back: HandedBack) => void): () => void {
  listeners.add(listener);
  return () => void listeners.delete(listener);
}

/// `draft` without the handed-back `text`, with the blank lines that joined it to its neighbours.
/// Unchanged when the person has edited the copy since (then it is theirs, not a replay).
export function withoutHandedBack(draft: string, text: string): string {
  const at = text.trim() ? draft.indexOf(text) : -1;
  if (at < 0) return draft;
  const before = draft.slice(0, at).replace(/\n{1,2}$/, "");
  const after = draft.slice(at + text.length).replace(/^\n{1,2}/, "");
  return before && after ? `${before}\n\n${after}` : before + after;
}
