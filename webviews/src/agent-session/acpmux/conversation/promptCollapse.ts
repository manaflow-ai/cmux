// A long prompt collapses as Claude's does (Leo 2026-10-21): its first twenty lines, the last one
// fading out, with Show more / Show less under them (UserBubble.tsx). It is one fold for the whole
// message: a block the composer sent as a paste is part of the message's one text body
// (`oneBody`), never a card or a fold of its own inside the bubble (ask-14d16a6247; Leo,
// 2026-11-07: "Like just don't separate these out. And, like, I thought we said, you know, remove
// these inner bubbles, inner, inner cards."). model.ts estimates the row from the same numbers, so
// a prompt that mounts moves nothing below it.

import { sliceWhole } from "../../../ui/wholeChars";
import { agentText } from "../agentText";
import type { PromptContentPart } from "../model";

/// A prompt taller than this many lines opens collapsed to them: twenty, twice the ten it was (Leo,
/// 2026-11-07: "I feel like we should show more than we are showing right now"). conversation.css
/// `.cv-user__text.is-clamped` clamps at the same count.
export const COLLAPSED_PROMPT_LINES = 20;
/// The Show more line under a collapsed prompt (`.cv-user__more`: 4px above a 20px line).
export const PROMPT_MORE_HEIGHT = 24;
/// The "Pasted from <agent>" line over a paste another agent wrote, which stays apart from the
/// person's words (PromptText.tsx PastedText): a 20px line 4px over the paste (`.cv-user__pasted-from`).
export const PASTE_FROM_HEIGHT = 24;
/// Before the bubble is laid out (and where it never is), a prompt longer than this many
/// characters is taken to wrap past the collapsed lines.
const LONG_PROMPT_CHARS = 2_000;

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
/// head (`HUGE_PROMPT_HEAD_CHARS`), far more than twenty lines at any width; Show more draws it whole.
export const HUGE_PROMPT_CHARS = 200_000;
export const HUGE_PROMPT_HEAD_CHARS = 4_000;

export const isHugePrompt = (text: string) => text.length > HUGE_PROMPT_CHARS;

/// Whether a prompt's text makes it huge: one of its text parts is. Run it on the parts `oneBody`
/// joined, so a paste counts as the message's text it is.
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

/// A line break as pasted text can carry it: \n, \r\n, a lone \r (classic Mac text), or Unicode's
/// line and paragraph separators (U+2028, U+2029), which rich-text editors put for a soft return.
/// The prompt field's own paste turns \r into \n; a VS Code paste, a drop and a file keep theirs.
export const PASTE_LINE_BREAK = /\r\n|[\n\r\u2028\u2029]/g;

/// A paste chip's name: the paste's first words, on one line.
export function pasteName(text: string): string {
  const line = text.split(PASTE_LINE_BREAK).find((candidate) => candidate.trim()) ?? "";
  const words = line.trim().replace(/\s+/g, " ");
  return words.length > 40 ? `${sliceWhole(words, 39).trimEnd()}…` : words;
}

/// A paste's line count (a final line break ends its last line, not a new one). Counts every break
/// PASTE_LINE_BREAK names, so text whose lines end in \r or U+2028 is not "1 line".
export function pasteLines(text: string): number {
  const body = text.replace(/(?:\r\n|[\n\r\u2028\u2029])$/, "");
  return (body.match(PASTE_LINE_BREAK)?.length ?? 0) + 1;
}

/// How the runs of one sent message's text join where a paste meets typed text or another paste
/// (sentPasteJoin.experiment.ts): as the draft had them, with a blank line, or with a line break.
export type PasteJoin = "typed" | "paragraph" | "line";

/// One run of a body: its text, and whether the person typed it (else it was pasted).
export type BodyRun = { text: string; typed: boolean };

/// One body's text from its runs, in order. `typed` keeps what was between them in the draft:
/// `between` is "" for runs the composer placed, where the space or line breaks typed around a
/// paste are typed runs of their own, so a typed run meets a paste with nothing between; two pastes
/// side by side, or a run and a paste that meet with no space at all (a big paste's chip put right
/// after a word), get acpmux's line break. `between` is "\n" for a record that kept only acpmux's
/// join of its text blocks (hub/session.rs `prompt_text`), so a recorded prompt reads as recorded.
/// `paragraph` and `line` drop the blank lines at each run's ends and runs of only space, and put a
/// blank line or one line break between the rest.
export function joinRuns(runs: readonly BodyRun[], join: PasteJoin, between: string): string {
  if (join === "typed")
    return runs.reduce((text, run, index) => {
      if (index === 0) return run.text;
      const last = runs[index - 1]!;
      const asDrafted = (last.typed || run.typed) && (/\s$/.test(last.text) || /^\s/.test(run.text));
      return text + (between || asDrafted ? between : "\n") + run.text;
    }, "");
  return runs
    .map(({ text }) =>
      text.replace(/^(?:[ \t]*(?:\r\n|[\n\r\u2028\u2029]))+|(?:(?:\r\n|[\n\r\u2028\u2029])[ \t]*)+$/g, ""),
    )
    .filter((text) => text.trim() !== "")
    .join(join === "paragraph" ? "\n\n" : "\n");
}

/// A sent message's parts with each run of typed text and the person's pastes made one text part:
/// the message is one continuous body, and only what `joins` leaves out (an attachment, a paste
/// another agent wrote) stands apart from it. `joins` gives a part's text when it is part of the
/// body, else undefined.
export function oneBody<T extends { kind: string }>(
  parts: readonly T[],
  joins: (part: T) => string | undefined,
  join: PasteJoin,
  between: string,
): (T | { kind: "text"; text: string })[] {
  const out: (T | { kind: "text"; text: string })[] = [];
  let run: BodyRun[] = [];
  const flush = () => {
    const text = run.length ? joinRuns(run, join, between) : "";
    if (text) out.push({ kind: "text", text });
    run = [];
  };
  for (const part of parts) {
    const text = joins(part);
    if (text === undefined) {
      flush();
      out.push(part);
    } else run.push({ text, typed: part.kind === "text" });
  }
  flush();
  return out;
}

/// Whether a paste stands apart from the message's body: one that reads as another agent's output
/// (agentText.ts), which keeps its "Pasted from" line (ask-fa4c523fa8). Every other paste is the
/// person's words, part of the body.
export const agentPaste = (text: string) => agentText(text).signals.length > 0;

/// A recorded prompt (its text and `user_message.pasted` ranges) as its bubble draws it: one body
/// of its typed text and the person's pastes, a paste another agent wrote apart. The record kept
/// only acpmux's join of its text blocks, so as typed it reads as recorded.
export const recordedBody = (text: string, pasted: readonly PasteRange[], join: PasteJoin) =>
  oneBody(
    promptParts(text, pasted),
    (part) => (part.kind === "paste" && agentPaste(part.text) ? undefined : part.text),
    join,
    "\n",
  );

/// The text of a body `drawnBody` gave, as the bubble draws it: each text part (the runs as
/// `joinRuns` joined them) and each paste apart from it, a line break between two of them, where
/// the bubble starts a new line (InlinePromptContent.tsx; a paste apart is a block of its own). An
/// attachment draws only as its chip, so a text file's body is not in it.
export function bodyText(body: readonly { kind: string; text?: string }[]): string {
  return body.flatMap((part) => (part.kind === "text" || part.kind === "pasted" ? (part.text ?? []) : [])).join("\n");
}

/// What Find reads of a body `drawnBody` gave: its `bodyText`, and each text file's body where its
/// chip draws it, opened (InlinePromptContent.tsx PromptTextFile, which Find opens to a match, as
/// it opened the paste card that drew it before). The fold measures `bodyText` alone: closed, a
/// file's body takes no room.
export function findBodyText(body: readonly PromptContentPart[]): string {
  return body
    .flatMap((part) =>
      part.kind === "text" || part.kind === "pasted"
        ? (part.text ?? [])
        : part.kind === "file"
          ? (blockText(part) ?? [])
          : [],
    )
    .join("\n");
}

/// A placed prompt's text as Find reads it (`findBodyText` of its `drawnBody`), so typed words and
/// a paste joined as the draft had them search as they read, and a text file's body is found behind
/// its chip. A match never points at undrawn words, nor misses one across a paste's edge.
export const drawnPromptText = (parts: readonly PromptContentPart[], join: PasteJoin) =>
  findBodyText(drawnBody(parts, join));

/** The text block a part went to the agent as (typed text, a pasted block, a text file's body), or
 * none for an attachment. */
export function blockText(part: PromptContentPart): string | undefined {
  if (part.kind === "text") return part.text;
  if (part.kind === "pasted" || (part.kind === "file" && !part.uri)) return part.text;
  return undefined;
}

/** The parts the strip setting moves to the band above the bubble: attachments, not what reads as
 * the prompt's text (typed text, pasted blocks and a text file's body stay in the bubble, as a
 * legacy prompt's do), so the bubble keeps the recorded text whole. */
export function isStripMedia(part: PromptContentPart): part is Exclude<PromptContentPart, { kind: "text" }> {
  return blockText(part) === undefined;
}

/** A part's text when it is part of the message's one body: typed text, or a paste of the
 * person's (not one another agent wrote, which stands apart with its "Pasted from" line). */
function bodyPartText(part: PromptContentPart): string | undefined {
  if (part.kind === "text") return part.text;
  if (part.kind === "pasted" && part.text !== undefined && !agentPaste(part.text)) return part.text;
  return undefined;
}

/// A placed prompt's parts as its bubble draws them (InlinePromptContent.tsx): one text body of its
/// typed words and the person's pastes between two attachments, as the draft read; a paste another
/// agent wrote apart; each attachment (a text file too) its chip, its body undrawn. What the bubble
/// draws and the row's height estimate measures (model.ts), so the two never disagree.
export const drawnBody = (parts: readonly PromptContentPart[], join: PasteJoin) =>
  oneBody(parts, bodyPartText, join, "");

/// The parts a recorded prompt draws in its bubble in their order (UserBubble.tsx `hasInterleaved`),
/// or undefined when it keeps the legacy bands above a bubble of its recorded text. Placed: the pane
/// marked an attachment so, or text follows an attachment, which the old shape never has. A placed
/// prompt's attachment the composer left in the strip (unmarked) draws in the band, not the bubble.
export function inlineBubbleParts(parts: readonly PromptContentPart[]): PromptContentPart[] | undefined {
  const firstMedia = parts.findIndex((part) => part.kind !== "text");
  if (firstMedia < 0) return undefined;
  const placed = parts.some((part) => part.kind !== "text" && part.placed === true);
  const interleaved = placed
    ? parts.some((part) => !isStripMedia(part))
    : parts.slice(firstMedia + 1).some((part) => part.kind === "text");
  if (!interleaved) return undefined;
  return placed ? parts.filter((part) => !isStripMedia(part) || part.placed === true) : [...parts];
}
