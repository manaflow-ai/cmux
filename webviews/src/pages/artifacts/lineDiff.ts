// A revision's change to a text file as unified hunks: the common prefix and suffix are trimmed, the
// rest is a longest-common-subsequence diff, and each hunk keeps a few lines of context. Past
// `MAX_CELLS` of table the middle shows as removed then added, so a huge file costs no more.

/** `noNewline`: the file ends on this line with no newline after it, as git's "\\ No newline at end of file". */
export type DiffLine = { type: "context" | "add" | "del"; text: string; noNewline?: boolean };
export type DiffHunk = DiffLine[];

/** A line of one side: its text, and whether the file ends on it with no newline after it. */
type Line = { text: string; noNewline: boolean };

const CONTEXT = 3;
const MAX_CELLS = 4_000_000;

export function lineHunks(before: string, after: string, context = CONTEXT): DiffHunk[] {
  const lines = lineDiff(split(before), split(after));
  // The index of the next change at or after each line, read from the end once.
  const nextChanges = new Int32Array(lines.length);
  let upcoming = -1;
  for (let at = lines.length - 1; at >= 0; at--) {
    if (lines[at]!.type !== "context") upcoming = at;
    nextChanges[at] = upcoming;
  }
  const hunks: DiffHunk[] = [];
  let hunk: DiffHunk | undefined;
  let since = Infinity;
  lines.forEach((line, index) => {
    if (line.type !== "context") {
      if (!hunk) {
        hunk = lines.slice(Math.max(0, index - context), index);
        hunks.push(hunk);
      }
      hunk.push(line);
      since = 0;
      return;
    }
    since += 1;
    if (!hunk) return;
    // Context after a change, then a gap wider than two contexts closes the hunk.
    const nextChange = nextChanges[index]!;
    if (since <= context || (nextChange !== -1 && nextChange - index <= context)) hunk.push(line);
    else hunk = undefined;
  });
  return hunks;
}

/** Its lines; the last one says when no newline follows it, so adding or dropping one is a change. */
function split(text: string): Line[] {
  if (!text) return [];
  const parts = text.split("\n");
  const ends = parts.at(-1) === "";
  if (ends) parts.pop();
  return parts.map((part, index) => ({ text: part, noNewline: !ends && index === parts.length - 1 }));
}

const same = (a: Line, b: Line) => a.text === b.text && a.noNewline === b.noNewline;

function line(type: DiffLine["type"], { text, noNewline }: Line): DiffLine {
  return noNewline ? { type, text, noNewline } : { type, text };
}

function lineDiff(a: Line[], b: Line[]): DiffLine[] {
  let start = 0;
  while (start < a.length && start < b.length && same(a[start]!, b[start]!)) start += 1;
  let end = 0;
  while (end < a.length - start && end < b.length - start && same(a[a.length - 1 - end]!, b[b.length - 1 - end]!))
    end += 1;
  const head = a.slice(0, start).map((item) => line("context", item));
  const tail = a.slice(a.length - end).map((item) => line("context", item));
  return [...head, ...middle(a.slice(start, a.length - end), b.slice(start, b.length - end)), ...tail];
}

function middle(x: Line[], y: Line[]): DiffLine[] {
  const del = x.map((item) => line("del", item));
  const add = y.map((item) => line("add", item));
  if (!x.length || !y.length || (x.length + 1) * (y.length + 1) > MAX_CELLS) return [...del, ...add];
  // lcs[i][j]: the common subsequence length of x[i..] and y[j..], one row per line of x.
  const width = y.length + 1;
  const lcs = new Uint32Array((x.length + 1) * width);
  for (let i = x.length - 1; i >= 0; i--)
    for (let j = y.length - 1; j >= 0; j--)
      lcs[i * width + j] = same(x[i]!, y[j]!)
        ? lcs[(i + 1) * width + j + 1]! + 1
        : Math.max(lcs[(i + 1) * width + j]!, lcs[i * width + j + 1]!);
  const out: DiffLine[] = [];
  let i = 0;
  let j = 0;
  while (i < x.length && j < y.length) {
    if (same(x[i]!, y[j]!)) {
      out.push(line("context", x[i]!));
      i += 1;
      j += 1;
    } else if (lcs[(i + 1) * width + j]! >= lcs[i * width + j + 1]!) out.push(line("del", x[i++]!));
    else out.push(line("add", y[j++]!));
  }
  while (i < x.length) out.push(line("del", x[i++]!));
  while (j < y.length) out.push(line("add", y[j++]!));
  return out;
}
