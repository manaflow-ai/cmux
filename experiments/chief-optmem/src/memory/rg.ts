/**
 * Memory search is a plain scan of the log, ripgrep style: no index, no
 * ranking, every line ever written is searched word for word. The flags are
 * a subset of rg's, with rg's meanings; case is smart by default (insensitive
 * unless the pattern has an uppercase letter), as `rg -S`.
 */

export interface RgQuery {
  readonly pattern: RegExp;
  readonly before: number;
  readonly after: number;
}

export type RgParse = RgQuery | { readonly error: "usage" } | { readonly error: "regex"; readonly message: string };

/** Uppercase letters outside escapes (`\S`, `\W` and `\p{Lu}` do not count), as rg's smart case. */
const hasUppercase = (pattern: string) => /\p{Lu}/u.test(pattern.replace(/\\p\{[^}]*\}|\\./gu, ""));

const escapeRegex = (s: string) => s.replace(/[.*+?^${}()|[\]\\/-]/g, "\\$&");

const count = (v: string | undefined) => (v !== undefined && /^\d+$/.test(v) ? Number(v) : undefined);

/**
 * Parses `[-i|-s|-S] [-F] [-w] [-A N] [-B N] [-C N] [--] PATTERN`. Flags may
 * be combined (`-iF`) and counts attached (`-C2`).
 */
export function parseRg(args: ReadonlyArray<string>): RgParse {
  let caseMode: "smart" | "insensitive" | "sensitive" = "smart";
  let fixed = false;
  let word = false;
  let before = 0;
  let after = 0;
  let pattern: string | undefined;
  for (let i = 0; i < args.length; i++) {
    const a = args[i]!;
    if (pattern === undefined && a === "--") {
      if (i !== args.length - 2) return { error: "usage" };
      pattern = args[i + 1]!;
      break;
    }
    if (pattern !== undefined || !a.startsWith("-") || a === "-") {
      if (pattern !== undefined) return { error: "usage" };
      pattern = a;
      continue;
    }
    for (let j = 1; j < a.length; j++) {
      const f = a[j]!;
      if (f === "i") caseMode = "insensitive";
      else if (f === "s") caseMode = "sensitive";
      else if (f === "S") caseMode = "smart";
      else if (f === "F") fixed = true;
      else if (f === "w") word = true;
      else if (f === "A" || f === "B" || f === "C") {
        const attached = a.slice(j + 1);
        const n = count(attached || args[++i]);
        if (n === undefined) return { error: "usage" };
        if (f !== "B") after = n;
        if (f !== "A") before = n;
        break;
      } else return { error: "usage" };
    }
  }
  if (pattern === undefined || pattern === "") return { error: "usage" };
  let source = fixed ? escapeRegex(pattern) : pattern;
  if (word) source = `(?<![\\p{L}\\p{N}_])(?:${source})(?![\\p{L}\\p{N}_])`;
  const insensitive = caseMode === "insensitive" || (caseMode === "smart" && !hasUppercase(pattern));
  try {
    return { pattern: new RegExp(source, insensitive ? "iu" : "u"), before, after };
  } catch (e) {
    return { error: "regex", message: (e as Error).message };
  }
}

export interface RgResult {
  /** Output lines, oldest first: matches, context, and `--` between separate groups. */
  readonly lines: Array<string>;
  /** Matching entries in the whole log. */
  readonly hits: number;
  /** Matching entries among `lines` (fewer than hits when the cap dropped old ones). */
  readonly shown: number;
}

/**
 * Streams the log once and keeps only the newest output that fits `cap` bytes
 * (each line counted with its newline), so a vague pattern over a million
 * entries never holds more than one part.
 */
export function rg(lines: Iterable<string>, query: RgQuery, cap: number, byteLength: (s: string) => number): RgResult {
  const out: Array<{ text: string; match: boolean }> = [];
  let head = 0;
  let size = 0;
  let hits = 0;
  let afterLeft = 0;
  let last = -1; // index of the last line written
  const prev: Array<{ i: number; text: string }> = [];
  const context = query.before > 0 || query.after > 0;
  const push = (text: string, match: boolean) => {
    out.push({ text, match });
    size += byteLength(text) + 1;
    while (size > cap && head < out.length) size -= byteLength(out[head++]!.text) + 1;
  };
  let i = 0;
  for (const line of lines) {
    if (query.pattern.test(line)) {
      hits++;
      const first = prev.length > 0 ? prev[0]!.i : i;
      if (context && last >= 0 && first > last + 1) push("--", false);
      for (const p of prev) push(p.text, false);
      prev.length = 0;
      push(line, true);
      last = i;
      afterLeft = query.after;
    } else if (afterLeft > 0) {
      push(line, false);
      last = i;
      afterLeft--;
    } else if (query.before > 0) {
      prev.push({ i, text: line });
      if (prev.length > query.before) prev.shift();
    }
    i++;
  }
  const kept = out.slice(head);
  while (kept[0]?.text === "--" && !kept[0].match) kept.shift();
  return { lines: kept.map((l) => l.text), hits, shown: kept.filter((l) => l.match).length };
}
