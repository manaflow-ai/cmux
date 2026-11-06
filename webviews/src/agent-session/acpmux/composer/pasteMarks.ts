// The composer knows what was pasted, so a paste goes as pasted, never as the person's own words
// (ask-fa4c523fa8; Leo, 2026-11-06: "it should be automatically attributable, so it doesn't just
// pass off as one of my messages"). A huge paste is already a chip (pastedChips.ts); a paste that
// stays in the draft as text is remembered here, and when the prompt goes, each one still in its
// text as pasted becomes a placed paste chip in its place: its own block marked `_meta.cmux.pasted`
// (attachments.ts `promptBlocks`), which acpmux records as a pasted range and the agent reads
// between "pasted by the person" marks (hub/prompt_attribution.rs). The text sent is the same.
//
// A short one-line paste (a path, a word, a name) stays the person's text: it is not a block of
// someone else's words. A paste the person edited is theirs too, no longer found as it was; acpmux
// still notes one that reads as another agent's (`agentText`).
import { type ComposerAttachment, INLINE_ATTACHMENT_MARK, inlineToken } from "../attachments";
import { pastedTextAttachment } from "../pastedText";
import { readsAsAgent } from "../agentText";

/// A paste of at least this many characters, or more than one line, goes as a block of its own.
export const MARKED_PASTE_CHARS = 200;
/// The pastes a draft remembers, newest kept: a draft rarely holds more, and the send's scan stays
/// bounded however much was pasted and deleted.
export const REMEMBERED_PASTES = 16;

/// Whether a paste of `text` that stays in the draft goes as a pasted block.
export function marksPaste(text: string): boolean {
  const body = text.trim();
  if (!body) return false;
  return body.length >= MARKED_PASTE_CHARS || /\S[^\S\n]*\n[\s\S]*\S/.test(body) || readsAsAgent(body);
}

/// `pastes` remembered with `text` added, oldest dropped past REMEMBERED_PASTES. The same text
/// pasted twice is remembered twice: each copy in the draft goes as pasted.
export function remember(pastes: readonly string[], text: string): string[] {
  if (!marksPaste(text)) return [...pastes];
  return [...pastes, text].slice(-REMEMBERED_PASTES);
}

/// The prompt with each remembered paste still in `text` as pasted put in its place as a placed
/// paste chip: as many copies as were pasted, the longest pastes first so a paste inside another
/// is not cut out of it. A paste is found by its text without the space or line breaks around it
/// (the prompt goes trimmed, and the field may drop a trailing line break), so words typed before
/// or after it stay the person's. Text that holds an attachment's mark is left as it is (it is no
/// plain paste any more), and so is any part of the text already placed.
export function markPastes(
  prompt: { text: string; attachments: ComposerAttachment[] },
  pastes: readonly string[],
): { text: string; attachments: ComposerAttachment[] } {
  const counts = new Map<string, number>();
  for (const paste of pastes) {
    const needle = paste.trim();
    if (needle && !needle.includes(INLINE_ATTACHMENT_MARK)) counts.set(needle, (counts.get(needle) ?? 0) + 1);
  }
  // The text as runs: plain text still to search, and the tokens of chips placed so far.
  let runs: { text: string; placed: boolean }[] = [{ text: prompt.text, placed: false }];
  const added: ComposerAttachment[] = [];
  for (const [needle, count] of [...counts].sort((a, b) => b[0].length - a[0].length)) {
    let left = count;
    runs = runs.flatMap((run) => {
      if (run.placed || left === 0) return [run];
      const out: { text: string; placed: boolean }[] = [];
      let rest = run.text;
      let at = rest.indexOf(needle);
      while (at >= 0 && left > 0) {
        const chip: ComposerAttachment = { ...pastedTextAttachment(needle), inline: true };
        added.push(chip);
        if (at > 0) out.push({ text: rest.slice(0, at), placed: false });
        out.push({ text: inlineToken(chip.id), placed: true });
        rest = rest.slice(at + needle.length);
        left -= 1;
        at = rest.indexOf(needle);
      }
      if (rest) out.push({ text: rest, placed: false });
      return out;
    });
  }
  if (!added.length) return prompt;
  return { text: runs.map((run) => run.text).join(""), attachments: [...prompt.attachments, ...added] };
}
