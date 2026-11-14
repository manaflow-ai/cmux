// Where a card may stop a Markdown text it has only part of (Leo, 2026-11-09, on a "Subagent
// finished" card that printed `**24 clean, f…` and stopped: "whoa this isn't rendering the full
// message nor having a show more as it shuold"). A text acpmux capped (a subagent's `lastMessage`,
// a notification's summary, a reply's tail) is cut at a character count, often inside a bold span,
// a link or a code fence, and Markdown then draws the span's marks as text. A card that has only
// such a text shows its whole blocks (paragraphs, list items, fenced code) and nothing of the block
// the cut went through, with Show more for the rest; it never draws a cut span.

/// The mark acpmux ends a capped text with (subagents.rs `truncate_last_message`, inbox.rs).
const ELLIPSIS = "…";
/// A list item's first line: `- `, `* `, `+ `, `1. `, `1) `, a task box after any of them.
const ITEM = /^\s{0,3}(?:[-*+]|\d{1,9}[.)])\s/;
const FENCE = /^\s{0,3}(`{3,}|~{3,})/;

/// Whether `text` is a capped preview: `chars` characters (acpmux's cap) or fewer once trimmed,
/// ending in its ellipsis. A whole message that happens to end in "…" is shorter than a cap.
export function isCappedPreview(text: string, chars: number): boolean {
  const trimmed = text.trimEnd();
  if (!trimmed.endsWith(ELLIPSIS)) return false;
  // Code points, as acpmux counts its cap (Rust `chars`).
  const length = Array.from(trimmed).length;
  return length <= chars && length >= chars - 8;
}

/// Which lines of a text are in a fenced code block (its fence lines count as in it), so a blank
/// line in a fence never splits a block; `open` is the line of a fence the text leaves open.
function fencedLines(lines: readonly string[]): { inside: boolean[]; open?: number } {
  const inside: boolean[] = [];
  let fenceOf: { mark: string; line: number } | undefined;
  lines.forEach((line, at) => {
    const fence = FENCE.exec(line)?.[1];
    if (fenceOf) {
      inside.push(true);
      const closes = fence && fence[0] === fenceOf.mark[0] && fence.length >= fenceOf.mark.length;
      if (closes && !line.trim().slice(fence.length)) fenceOf = undefined;
    } else {
      inside.push(fence !== undefined);
      if (fence) fenceOf = { mark: fence, line: at };
    }
  });
  return { inside, open: fenceOf?.line };
}

/// The whole blocks of a text cut at its end: every block before the one the cut went through and,
/// when that one is a list, its whole items before the cut one. Empty when the cut went through
/// the first block.
export function wholeBlocksBefore(text: string): string {
  const lines = text.trimEnd().replace(/…$/u, "").split("\n");
  const { inside, open } = fencedLines(lines);
  // A fence the cut left open is the cut block; else it starts after the last blank line outside
  // a fence.
  let start = open ?? 0;
  if (open === undefined)
    lines.forEach((line, at) => {
      if (!inside[at] && !line.trim()) start = at + 1;
    });
  // A list block keeps its items before the one the cut went through.
  let keep = start;
  if (open === undefined && ITEM.test(lines[start] ?? ""))
    for (let at = start; at < lines.length; at += 1) if (!inside[at] && ITEM.test(lines[at]!)) keep = at;
  return lines.slice(0, keep).join("\n").trimEnd();
}

/// The whole blocks of a text cut at its start (a tail acpmux kept, "…the rest"): every block after
/// the one the cut went through.
export function wholeBlocksAfter(text: string): string {
  const lines = text.trimStart().replace(/^…/u, "").split("\n");
  // A tail that starts in code leaves a fence open when read from its top (a whole one never
  // does): its first bare fence line closes that code and ends the cut block, so what follows is
  // whole. A longer fence holding a shorter one's literal reads as closed and is kept.
  if (fencedLines(lines).open !== undefined) {
    const close = lines.findIndex((line) => FENCE.test(line) && !line.trim().replace(/^(`{3,}|~{3,})/, ""));
    return close < 0
      ? ""
      : lines
          .slice(close + 1)
          .join("\n")
          .trim();
  }
  const { inside } = fencedLines(lines);
  // The first blank line outside a fence ends the cut block.
  for (let at = 0; at < lines.length; at += 1)
    if (!inside[at] && !lines[at]!.trim())
      return lines
        .slice(at + 1)
        .join("\n")
        .trim();
  return "";
}

/// The plain words of a block, its Markdown marks dropped, for a cut that leaves no whole block:
/// the card still says something, and draws no mark as text.
export function plainWords(text: string): string {
  return text
    .replace(/…$/u, "")
    .replace(/^\s*(?:#{1,6}\s+|>\s*|[-*+]\s+(?:\[[ xX]\]\s+)?|\d{1,9}[.)]\s+)/gm, "")
    .replace(/!?\[([^\]]*)\]\([^)]*\)?/g, "$1")
    .replace(/(\*\*|__|`+|~~|[*_](?=\S)|(?<=\S)[*_])/g, "")
    .replace(/\s+/g, " ")
    .trim();
}

/// What a card shows of a text cut at its end: its whole blocks, else the first block's plain
/// words with the ellipsis (never a cut span's marks).
export function shownOfCut(text: string): string {
  const whole = wholeBlocksBefore(text);
  if (whole) return whole;
  const words = plainWords(text);
  return words ? `${words.replace(/([\\`*_[\]<>#])/g, "\\$1")}${ELLIPSIS}` : "";
}
