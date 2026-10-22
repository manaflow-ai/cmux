// A long prompt collapses as Claude's does (Leo 2026-10-21): its first ten lines, the last ones
// fading out, with Show more / Show less under them (UserBubble.tsx). A block the composer sent as
// a paste is a chip, "<first words> · N lines", that opens in place. model.ts estimates the row
// from the same numbers, so a prompt that mounts moves nothing below it.

/// A prompt taller than this many lines opens collapsed to them.
export const COLLAPSED_PROMPT_LINES = 10;
/// The Show more line under a collapsed prompt (`.cv-user__more`: 4px above a 20px line).
export const PROMPT_MORE_HEIGHT = 24;
/// A pasted block's chip as the bubble draws it closed (`.cv-user__paste-block`: a 32px chip in
/// 4px above and below).
export const PASTE_CHIP_HEIGHT = 40;
/// Before the bubble is laid out (and where it never is), a prompt longer than this many
/// characters is taken to wrap past the collapsed lines.
const LONG_PROMPT_CHARS = 1_000;

/// The collapsed height of prompt content `height` tall in `lineHeight` lines: itself when it fits
/// the collapsed lines, else those lines and the Show more line.
export function collapsedPromptHeight(height: number, lineHeight: number): number {
  const limit = COLLAPSED_PROMPT_LINES * lineHeight;
  return height > limit + 1 ? limit + PROMPT_MORE_HEIGHT : height;
}

/// Whether a prompt is likely taller than the collapsed lines, before it is laid out.
export const looksLongPrompt = (text: string) =>
  text.length > LONG_PROMPT_CHARS || text.split("\n", COLLAPSED_PROMPT_LINES + 1).length > COLLAPSED_PROMPT_LINES;

/// A pasted block of a prompt's text: UTF-16 offsets, `start` inclusive, `end` exclusive.
export type PasteRange = { start: number; end: number };

/// The pasted blocks a `user_message` names (`pasted: [{start, end}]`), as acpmux records the
/// prompt's text blocks the composer marked `_meta.cmux.pasted`: sorted, inside `text`, non-empty
/// and not overlapping. Anything else is left out, so a malformed record draws plain text.
export function pasteRanges(value: unknown, text: string): PasteRange[] {
  if (!Array.isArray(value)) return [];
  const ranges = value
    .filter(
      (range): range is PasteRange =>
        typeof range === "object" &&
        range !== null &&
        Number.isInteger((range as PasteRange).start) &&
        Number.isInteger((range as PasteRange).end),
    )
    .map(({ start, end }) => ({ start, end }))
    .filter(({ start, end }) => start >= 0 && end <= text.length && start < end)
    .sort((a, b) => a.start - b.start);
  const kept: PasteRange[] = [];
  for (const range of ranges) if (!kept.length || range.start >= kept.at(-1)!.end) kept.push(range);
  return kept;
}

/// A prompt's text cut at its pasted blocks: the typed parts, without the line break that joined
/// each to a paste (acpmux joins a prompt's text blocks with one), and the pastes.
export type PromptPart = { kind: "text"; text: string } | { kind: "paste"; text: string; index: number };

export function promptParts(text: string, ranges: readonly PasteRange[]): PromptPart[] {
  const parts: PromptPart[] = [];
  let at = 0;
  const typed = (from: number, to: number) => {
    let part = text.slice(from, to);
    if (from > 0) part = part.replace(/^\n/, "");
    if (to < text.length) part = part.replace(/\n$/, "");
    if (part) parts.push({ kind: "text", text: part });
  };
  ranges.forEach((range, index) => {
    typed(at, range.start);
    parts.push({ kind: "paste", text: text.slice(range.start, range.end), index });
    at = range.end;
  });
  typed(at, text.length);
  return parts;
}

/// A paste chip's name: the paste's first words, on one line.
export function pasteName(text: string): string {
  const line = text.split("\n").find((candidate) => candidate.trim()) ?? "";
  const words = line.trim().replace(/\s+/g, " ");
  return words.length > 40 ? `${words.slice(0, 39).trimEnd()}…` : words;
}

/// A paste's line count (a final line break ends its last line, not a new one).
export const pasteLines = (text: string) => text.replace(/\n$/, "").split("\n").length;
