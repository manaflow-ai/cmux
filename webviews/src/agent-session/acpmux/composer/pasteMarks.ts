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

/// `pastes` remembered with `text` added, oldest dropped past REMEMBERED_PASTES.
export function remember(pastes: readonly string[], text: string): string[] {
  if (!marksPaste(text)) return [...pastes];
  return [...pastes.filter((held) => held !== text), text].slice(-REMEMBERED_PASTES);
}

/// The prompt with each remembered paste still in `text` as pasted put in its place as a placed
/// paste chip, the longest first so a paste inside another is not cut out of it. Text that holds
/// an attachment's mark is left as it is (it is no plain paste any more).
export function markPastes(
  prompt: { text: string; attachments: ComposerAttachment[] },
  pastes: readonly string[],
): { text: string; attachments: ComposerAttachment[] } {
  let { text } = prompt;
  const added: ComposerAttachment[] = [];
  const longest = [...pastes].sort((a, b) => b.length - a.length);
  for (const paste of longest) {
    if (paste.includes(INLINE_ATTACHMENT_MARK)) continue;
    const at = text.indexOf(paste);
    if (at < 0) continue;
    const chip: ComposerAttachment = { ...pastedTextAttachment(paste), inline: true };
    text = text.slice(0, at) + inlineToken(chip.id) + text.slice(at + paste.length);
    added.push(chip);
  }
  return added.length ? { text, attachments: [...prompt.attachments, ...added] } : prompt;
}
