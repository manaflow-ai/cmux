// Whether an edit's changed lines get word-level marks. @pierre/diffs pairs each run's removed
// lines with its added lines by position; when a block is rewritten or shifted, the pairs share
// little and every word lights up. Marks are kept only where most pairs are a line edited.
import type { DiffEdit } from "../diff";

/// A pair counts as one line edited when this share of its words is common to both sides.
const SIMILAR = 0.5;
/// Marks show when at least this share of an edit's pairs are similar.
const ENOUGH = 0.6;

const words = (line: string) =>
  line
    .trim()
    .split(/\s+|(?=[^\w\s])|(?<=[^\w\s])/)
    .filter(Boolean);

/// The share of the two lines' words they have in common (Dice coefficient over word counts).
export function lineSimilarity(a: string, b: string): number {
  const left = words(a);
  const right = words(b);
  if (left.length + right.length === 0) return 1;
  const counts = new Map<string, number>();
  for (const word of left) counts.set(word, (counts.get(word) ?? 0) + 1);
  let common = 0;
  for (const word of right) {
    const count = counts.get(word) ?? 0;
    if (count > 0) {
      common += 1;
      counts.set(word, count - 1);
    }
  }
  return (2 * common) / (left.length + right.length);
}

/// The removed and added lines of each run, paired by position as the diff draws them.
export function changedPairs(edit: DiffEdit): [string, string][] {
  const pairs: [string, string][] = [];
  for (const hunk of edit.hunks) {
    let removed: string[] = [];
    let added: string[] = [];
    const flush = () => {
      for (let index = 0; index < Math.min(removed.length, added.length); index += 1)
        pairs.push([removed[index]!, added[index]!]);
      removed = [];
      added = [];
    };
    for (const line of hunk.lines) {
      if (line.type === "context" || (line.type === "del" && added.length > 0)) flush();
      if (line.type === "del") removed.push(line.text);
      else if (line.type === "add") added.push(line.text);
    }
    flush();
  }
  return pairs;
}

export function intralineMode(edit: DiffEdit): "word-alt" | "none" {
  const pairs = changedPairs(edit);
  if (pairs.length === 0) return "word-alt";
  const similar = pairs.filter(([a, b]) => lineSimilarity(a, b) >= SIMILAR).length;
  return similar / pairs.length >= ENOUGH ? "word-alt" : "none";
}
