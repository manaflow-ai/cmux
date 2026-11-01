// A long prompt collapses as Claude's does (Leo 2026-10-21): its first ten lines, the last one
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

/// A prompt longer than this many characters (a pasted log, a base64 blob) draws as literal text in
/// one text node: no Markdown, no link scan and no break points, each of which costs the main thread
/// per character or per token, and a prompt of megabytes froze the chat that held it (Leo,
/// 2026-10-31: "this is completely hardlocked bc of message size"). Collapsed, it draws only its
/// head (`HUGE_PROMPT_HEAD_CHARS`), far more than ten lines at any width; Show more draws it whole.
export const HUGE_PROMPT_CHARS = 200_000;
export const HUGE_PROMPT_HEAD_CHARS = 4_000;

export const isHugePrompt = (text: string) => text.length > HUGE_PROMPT_CHARS;

/// Whether a prompt's typed text makes it huge: one of its typed parts is. Pasted blocks are chips
/// whatever their length (a huge paste draws as one chip, nothing more), so they never count.
export const hasHugeTypedPart = (parts: readonly { kind: string; text?: string }[]) =>
  parts.some((part) => part.kind === "text" && typeof part.text === "string" && isHugePrompt(part.text));

/// A huge prompt's typed parts as its collapsed bubble draws them: the parts within its first `chars`
/// characters of typed text, the last one cut short, and nothing after. A paste or an attachment is
/// a chip whatever its length, so it counts nothing. `huge` marks a part cut from a huge one, which
/// draws literally as its whole text does once open; a short part beside a big paste keeps its
/// Markdown.
export function headParts<T extends { kind: string }>(
  parts: readonly T[],
  chars: number,
  typed: (part: T) => string | undefined,
): (T & { huge?: boolean })[] {
  const out: (T & { huge?: boolean })[] = [];
  let left = chars;
  for (const part of parts) {
    if (left <= 0) break;
    const text = typed(part);
    if (text === undefined) {
      out.push(part);
      continue;
    }
    const head = promptHead(text, left);
    out.push(head === text ? part : { ...part, text: head, huge: isHugePrompt(text) });
    left -= head.length;
  }
  return out;
}

/// The first `chars` UTF-16 units of `text`, never ending inside a surrogate pair.
export function promptHead(text: string, chars: number): string {
  if (text.length <= chars) return text;
  const code = text.charCodeAt(chars - 1);
  return text.slice(0, code >= 0xd800 && code <= 0xdbff ? chars - 1 : chars);
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
