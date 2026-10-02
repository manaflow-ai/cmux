// Net change of a file over several patches, as the "Edited N files" card counts it.
//
// The desktop app counts the turn's unified diff (`turn/diff/updated`, the turn's net git
// diff), falling back to composing the turn's own patches (`Fhr`/`Ahr` in app-shared-*.js:
// consecutive in-place updates to one path, tracked by line provenance; renames, binary and
// mode changes bail out). Rollouts keep the patches, not the turn diff, so this composes
// them: the file is a sequence of original lines (identities, with their text once a patch
// shows it) and lines patches added. Applying every hunk in order gives the final sequence;
// the net diff is the line diff between the original and the final sequence, where an
// added line equals an original line with the same text. A line one patch rewrites and a
// later patch rewrites back counts as unchanged, as in the turn's git diff.

type Line = { orig: number; text?: string } | { orig?: undefined; text: string };

const HUNK = /^@@ -(\d+)(?:,(\d+))? \+\d+(?:,\d+)? @@/;

/** One patch's hunks: old start (1-based), old length and the hunk's lines. */
function hunks(diff: string) {
  const out: { start: number; length: number; lines: string[] }[] = [];
  for (const line of diff.split("\n")) {
    const m = HUNK.exec(line);
    if (m)
      out.push({ start: Number(m[1]), length: m[2] === undefined ? 1 : Number(m[2]), lines: [] });
    else if (out.length && /^[ +-]/.test(line)) out.at(-1)!.lines.push(line);
  }
  return out;
}

/**
 * Net additions and deletions of `diffs` applied in order to one file (each a unified diff
 * against the file as the previous ones left it). `created` starts from an empty file.
 */
export function netDiffStats(diffs: string[], { created = false } = {}) {
  const file: Line[] = [];
  let nextOrig = 0;
  const original: Line[] = [];
  /** Extend the file with untouched original lines up to `length`. */
  const pad = (length: number) => {
    while (!created && file.length < length) {
      const line: Line = { orig: nextOrig++ };
      file.push(line);
      original.push(line);
    }
  };
  for (const diff of diffs) {
    // Later hunks first, so earlier hunks' positions still hold.
    for (const h of hunks(diff).reverse()) {
      let pos = h.length === 0 ? h.start : h.start - 1;
      pad(pos + h.length);
      for (const l of h.lines) {
        const text = l.slice(1);
        if (l[0] === "+") file.splice(pos++, 0, { text });
        else {
          const line = file[pos];
          if (line && line.orig !== undefined) line.text ??= text;
          if (l[0] === "-") file.splice(pos, 1);
          else pos++;
        }
      }
    }
  }
  // Common ends are unchanged; diff the middle by longest common subsequence.
  const a = original;
  const b = file;
  const same = (x: Line, y: Line) =>
    x === y || (x.text !== undefined && y.orig === undefined && x.text === y.text);
  let lo = 0;
  while (lo < a.length && lo < b.length && same(a[lo]!, b[lo]!)) lo++;
  let ha = a.length;
  let hb = b.length;
  while (ha > lo && hb > lo && same(a[ha - 1]!, b[hb - 1]!)) {
    ha--;
    hb--;
  }
  const n = ha - lo;
  const m = hb - lo;
  const row = new Uint32Array(m + 1);
  for (let i = 1; i <= n; i++) {
    let diag = 0;
    for (let j = 1; j <= m; j++) {
      const up = row[j]!;
      row[j] = same(a[lo + i - 1]!, b[lo + j - 1]!) ? diag + 1 : Math.max(up, row[j - 1]!);
      diag = up;
    }
  }
  const common = row[m]!;
  return { additions: m - common, deletions: n - common };
}
