// A pull request an agent's message names twice in a row, written two ways ("MERGED #23825
// (4c656ea8) manaflow-ai/cmux#23825 — …"), draws as one chip (IncomingMessageCard.tsx): the second
// spelling goes when only spaces, punctuation and commit SHAs stand between the two. A later
// mention in another sentence ("… and #23825 needs a rebase") is the agent's words and stays.
import { githubReferences } from "../../../githubReferences";

/// What may stand between two spellings of one reference: spaces, brackets, separators and SHAs.
/// A SHA is a whole run of hex digits, so a long run is read one way only (never split in two).
const BETWEEN = /^[\s,;:()[\]/|=·•—–-]*(?:[0-9a-f]{7,40}(?![0-9a-f])[\s,;:()[\]/|=·•—–-]*)*$/;
/// What may follow a repeat that opens a bracket, up to its close: separators, SHAs and other
/// references ("#1 (o/r#1, abc1234, #1)"); words after it ("#5 (#5 broke main)") make it the
/// agent's own.
const BRACKET_REST = /^(?:[\s,;]|[0-9a-f]{7,40}(?![0-9a-f])|[\w.-]*(?:\/[\w.-]+)?#\d+)*\)/;
/// A line longer than this is left as written (its references are read once each, but its links
/// are not).
const LONGEST_LINE = 4000;
/// Stands in for a dropped repeat until the brackets it leaves empty go.
const DROPPED = "\uE000";
/// A fence's opening or closing line; a code span, a link or an image, which are never rewritten.
const FENCE = /^\s{0,3}(?:```|~~~)/;
const CODE_SPAN = /(`+)[^`\n]*?\1|!?\[[^\]\n]*\]\([^)\n]*\)/g;

/// `text` without the second spelling of a reference written twice in a row. `repository` is the
/// one a bare `#N` means (the transcript's).
export function dedupeReferences(text: string, repository?: string): string {
  if (!text.includes("#")) return text;
  let fenced = false;
  return text
    .split("\n")
    .map((line) => {
      if (FENCE.test(line)) {
        fenced = !fenced;
        return line;
      }
      return fenced ? line : dedupeLine(line, repository);
    })
    .join("\n");
}

function dedupeLine(line: string, repository?: string): string {
  if (!line.includes("#") || line.length > LONGEST_LINE || line.includes(DROPPED)) return line;
  // Code and links are never read: blanked to the same length, so every index still fits the
  // line, with a mark `BETWEEN` refuses, so a reference after one is never a repeat.
  const prose = line.replace(CODE_SPAN, (span) => "\u0000".repeat(span.length));
  const refs = githubReferences(prose, repository, "pull", true);
  const drop: { start: number; end: number }[] = [];
  // The last mention of each reference so far.
  const last = new Map<string, (typeof refs)[number]>();
  for (const ref of refs) {
    const key = ref.href.toLowerCase();
    const before = last.get(key);
    last.set(key, ref);
    if (!before || !BETWEEN.test(prose.slice(before.end, ref.start))) continue;
    // In brackets by itself ("o/r#1 (#1)"), the brackets go with it.
    if (line[ref.start - 1] === "(" && line[ref.end] === ")") {
      let start = ref.start - 1;
      while (start > before.end && /\s/.test(line[start - 1]!)) start--;
      push(drop, start, ref.end + 1);
      continue;
    }
    // Its separator before it goes too, unless that opens a bracket ("#1 (o/r#1, abc1234)").
    let start = ref.start;
    let end = ref.end;
    while (start > before.end && /[\s,;/|=·•—–-]/.test(line[start - 1]!)) start--;
    if (line[start - 1] === "(") {
      if (!BRACKET_REST.test(prose.slice(ref.end))) continue;
      while (end < line.length && /[\s,;]/.test(line[end]!)) end++;
    }
    push(drop, start, end);
  }
  if (!drop.length) return line;
  let out = "";
  let at = 0;
  for (const range of drop) {
    out += line.slice(at, range.start) + DROPPED;
    at = range.end;
  }
  out += line.slice(at);
  // Brackets left empty by the repeats they held go too ("#1 (o/r#1, #1)" is "#1"); an empty
  // bracket the agent wrote (`f()`) stays.
  return out.replace(/\s*\(\s*(?:\uE000[\s,;]*)+\)/g, "").replaceAll(DROPPED, "");
}

/// Adds a range to drop after the ones before it, never overlapping them.
function push(drop: { start: number; end: number }[], start: number, end: number): void {
  const after = drop.at(-1)?.end ?? 0;
  if (end > Math.max(start, after)) drop.push({ start: Math.max(start, after), end });
}
