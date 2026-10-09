// Prompt recall and large pastes for the chat composer (round 1 of the UI tournament, design A).
//
// Recall: in an empty field, Up shows the chat's previous prompts, newest first, and Down walks back
// to the empty draft. A recalled prompt the user edits is an ordinary draft again, so Up and Down
// move the caret as usual. The prompts are the chat's own user rows: nothing is stored.
//
// Large pastes: a plain-text paste above a size limit becomes a text attachment, so it does not
// flood the field (and the agent still gets the whole text).
import type { AcpmuxRow } from "../model";

/// The chat's sent prompts, oldest first, without repeats of the same prompt in a row.
export function sentPrompts(rows: readonly AcpmuxRow[]): string[] {
  const prompts: string[] = [];
  for (const row of rows) {
    if (row.kind !== "user" || typeof row.text !== "string") continue;
    const text = row.text.trim();
    if (!text || prompts[prompts.length - 1] === text) continue;
    prompts.push(text);
  }
  return prompts;
}

/// Where recall is: the index of the shown prompt (counted from the newest) and its text.
export type RecallState = { index: number; shown: string } | undefined;

/// One Up or Down. Returns the next state and the text to show, or undefined when the key is not
/// recall's: the draft is not empty and not the unchanged recalled prompt, or there is nothing to show.
export function recallStep(
  prompts: readonly string[],
  state: RecallState,
  draft: string,
  key: "ArrowUp" | "ArrowDown",
): { state: RecallState; text: string } | undefined {
  const recalling = state !== undefined && draft === state.shown;
  if (!recalling && draft.trim() !== "") return undefined;
  const current = recalling ? state.index : -1;
  const next = key === "ArrowUp" ? current + 1 : current - 1;
  if (next >= prompts.length) return undefined;
  if (next < 0) return recalling ? { state: undefined, text: "" } : undefined;
  const text = prompts[prompts.length - 1 - next];
  return { state: { index: next, shown: text }, text };
}

/// Plain text at or above either limit is pasted as an attachment.
export const LARGE_PASTE_CHARS = 8000;
export const LARGE_PASTE_LINES = 150;

export function lineCount(text: string): number {
  return text.length === 0 ? 0 : text.split(/\r\n|\r|\n/).length;
}

export function isLargePaste(text: string): boolean {
  return text.length >= LARGE_PASTE_CHARS || lineCount(text) >= LARGE_PASTE_LINES;
}
