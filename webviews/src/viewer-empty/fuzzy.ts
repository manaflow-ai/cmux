// The fuzzy filter of the path picker: the query's characters must appear in the name in order
// (case-insensitive). Higher scores rank first: a prefix match, then matches at word starts
// (after `-`, `_`, `.`, a space or a lower-to-upper case change), then contiguous runs. The same
// rules are meant for the app's palette picker, so both rank a folder level the same way.

/** The match score of `query` in `name`, or null when it does not match. An empty query is 0. */
export function fuzzyScore(query: string, name: string): number | null {
  if (query === "") return 0;
  const q = query.toLowerCase();
  const n = name.toLowerCase();
  if (n.startsWith(q)) return 1000 + (q.length === n.length ? 100 : 0) - n.length;
  let score = 0;
  let from = 0;
  let previous = -2;
  for (const char of q) {
    const index = n.indexOf(char, from);
    if (index < 0) return null;
    if (index === previous + 1) score += 8;
    if (index === 0 || isWordStart(name, index)) score += 12;
    score -= Math.min(index - from, 6);
    previous = index;
    from = index + 1;
  }
  const contiguous = n.indexOf(q);
  if (contiguous >= 0) score += 40 - Math.min(contiguous, 20);
  return score - n.length / 100;
}

function isWordStart(name: string, index: number): boolean {
  const before = name[index - 1];
  const char = name[index];
  if (before === undefined) return true;
  if ("-_. /".includes(before)) return true;
  return before === before.toLowerCase() && char !== char.toLowerCase();
}

/**
 * `items` filtered by `query`, best first; ties keep their order (so recent folders stay first).
 * Without a query the order is unchanged.
 */
export function fuzzyFilter<T>(items: readonly T[], query: string, name: (item: T) => string): T[] {
  if (query === "") return [...items];
  const scored: Array<{ item: T; score: number; index: number }> = [];
  items.forEach((item, index) => {
    const score = fuzzyScore(query, name(item));
    if (score != null) scored.push({ item, score, index });
  });
  scored.sort((a, b) => b.score - a.score || a.index - b.index);
  return scored.map((entry) => entry.item);
}
