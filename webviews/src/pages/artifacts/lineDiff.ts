// A revision's change to a text file as unified hunks: the common prefix and suffix are trimmed, the
// rest is a longest-common-subsequence diff, and each hunk keeps a few lines of context. Past
// `MAX_CELLS` of table the middle shows as removed then added, so a huge file costs no more.

/** `noNewline`: the file ends on this line with no newline after it, as git's "\\ No newline at end of file". */
export type DiffLine = { type: "context" | "add" | "del"; text: string; noNewline?: boolean };
export type DiffHunk = DiffLine[];

const CONTEXT = 3;
const MAX_CELLS = 4_000_000;

export function lineHunks(before: string, after: string, context = CONTEXT): DiffHunk[] {
  const lines = lineDiff(split(before), split(after));
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
    const nextChange = lines.findIndex((other, at) => at > index && other.type !== "context");
    if (since <= context || (nextChange !== -1 && nextChange - index <= context)) hunk.push(line);
    else hunk = undefined;
  });
  return hunks;
}

/** Its lines; a last line with no newline after it ends in ``NO_NEWLINE``, so adding one is a change. */
function split(text: string): string[] {
  if (!text) return [];
  const lines = text.split("\n");
  if (lines.at(-1) === "") lines.pop();
  else lines[lines.length - 1] += NO_NEWLINE;
  return lines;
}

/** Ends a last line with no newline after it while diffing; ``line`` turns it into `noNewline`. */
const NO_NEWLINE = "\u0000no-newline";

function line(type: DiffLine["type"], text: string): DiffLine {
  return text.endsWith(NO_NEWLINE)
    ? { type, text: text.slice(0, -NO_NEWLINE.length), noNewline: true }
    : { type, text };
}

function lineDiff(a: string[], b: string[]): DiffLine[] {
  let start = 0;
  while (start < a.length && start < b.length && a[start] === b[start]) start += 1;
  let end = 0;
  while (end < a.length - start && end < b.length - start && a[a.length - 1 - end] === b[b.length - 1 - end]) end += 1;
  const head = a.slice(0, start).map((text) => line("context", text));
  const tail = a.slice(a.length - end).map((text) => line("context", text));
  const x = a.slice(start, a.length - end);
  const y = b.slice(start, b.length - end);
  return [...head, ...middle(x, y), ...tail];
}

function middle(x: string[], y: string[]): DiffLine[] {
  const del = x.map((text) => line("del", text));
  const add = y.map((text) => line("add", text));
  if (!x.length || !y.length || (x.length + 1) * (y.length + 1) > MAX_CELLS) return [...del, ...add];
  // lcs[i][j]: the common subsequence length of x[i..] and y[j..], one row per line of x.
  const width = y.length + 1;
  const lcs = new Uint32Array((x.length + 1) * width);
  for (let i = x.length - 1; i >= 0; i--)
    for (let j = y.length - 1; j >= 0; j--)
      lcs[i * width + j] =
        x[i] === y[j]
          ? lcs[(i + 1) * width + j + 1]! + 1
          : Math.max(lcs[(i + 1) * width + j]!, lcs[i * width + j + 1]!);
  const out: DiffLine[] = [];
  let i = 0;
  let j = 0;
  while (i < x.length && j < y.length) {
    if (x[i] === y[j]) {
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
