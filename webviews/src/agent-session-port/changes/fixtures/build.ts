// Helpers that turn a compact description of a change (the lines that are visible in
// the reference capture plus counts of the lines hidden behind "N unmodified lines")
// into the full old/new file text that @pierre/diffs diffs itself.

/** Deterministic filler for lines that only appear as "N unmodified lines". */
export function filler(prefix: string, from: number, count: number): string[] {
  const out: string[] = [];
  for (let i = 0; i < count; i++) {
    const n = from + i;
    // Unique, plausible markdown-ish lines so the diff algorithm aligns them trivially.
    out.push(n % 7 === 0 ? "" : `${prefix} ${n}: retained note`);
  }
  return out;
}

export const join = (lines: readonly string[]) => lines.join("\n") + "\n";

/** Repeat a phrase list until a line reaches at least `length` characters. */
export function longLine(head: string, parts: readonly string[], length: number): string {
  let line = head;
  let i = 0;
  while (line.length < length) {
    line += parts[i % parts.length];
    i++;
  }
  return line.slice(0, length);
}

export interface Block {
  keep: number;
  del?: number;
  add?: number;
}

/** Build old/new line arrays from runs of kept, deleted and added lines. */
export function scattered(
  line: (kind: "keep" | "old" | "new", n: number) => string,
  blocks: readonly Block[],
) {
  const oldLines: string[] = [];
  const newLines: string[] = [];
  let k = 0;
  let o = 0;
  let a = 0;
  for (const b of blocks) {
    for (let i = 0; i < b.keep; i++) {
      const l = line("keep", k++);
      oldLines.push(l);
      newLines.push(l);
    }
    for (let i = 0; i < (b.del ?? 0); i++) oldLines.push(line("old", o++));
    for (let i = 0; i < (b.add ?? 0); i++) newLines.push(line("new", a++));
  }
  return { oldLines, newLines };
}
