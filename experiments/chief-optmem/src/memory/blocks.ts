/**
 * The block math of OptMem (github.com/VictorTaelin/OptMem, `memo`): a block
 * is an aligned power-of-two range [lo, hi) of log entries, summarized into
 * one line. Blocks form a binary merge tree over the log. Ranges here are
 * half-open; ids as people and models read them (`#lo-hi`) are inclusive.
 */

export type Block = readonly [lo: number, hi: number];

/**
 * Tiles [0, T) with aligned blocks, keeping a block whole when it ends inside
 * the log and its size is at most `alpha` times its age (T - lo). A larger
 * alpha keeps larger blocks whole, so the tiling has fewer lines.
 */
function tile(T: number, alpha: number): Array<Block> {
  let root = 1;
  while (root < T) root *= 2;
  const out: Array<Block> = [];
  const stack: Array<Block> = [[0, root]];
  while (stack.length > 0) {
    const [lo, hi] = stack.pop()!;
    if (lo >= T) continue;
    const size = hi - lo;
    if (size > 1 && (hi > T || size > alpha * (T - lo))) {
      const mid = (lo + hi) / 2;
      stack.push([mid, hi], [lo, mid]);
    } else {
      out.push([lo, hi]);
    }
  }
  return out.sort((a, b) => a[0] - b[0]);
}

/**
 * What a wake shows: at most `budget` blocks covering [0, T), finest near T.
 * Detail decays with age; when everything fits, every entry is shown as is.
 * The search and the float arithmetic follow the reference exactly, so both
 * pick the same alpha bit for bit.
 */
export function cover(T: number, budget: number): Array<Block> {
  if (T <= 0) return [];
  if (T <= budget) return Array.from({ length: T }, (_, i): Block => [i, i + 1]);
  let lo = 0;
  let hi = 1;
  for (let i = 0; i < 60; i++) {
    const mid = (lo + hi) / 2;
    if (tile(T, mid).length > budget) lo = mid;
    else hi = mid;
  }
  const out = tile(T, hi);
  // Sizes jump in powers of two, so the tiling can undershoot the budget:
  // spend the rest by splitting the newest multi-entry block, repeatedly.
  while (out.length < budget) {
    let i = -1;
    for (let j = out.length - 1; j >= 0; j--) {
      const [a, b] = out[j]!;
      if (b - a > 1) {
        i = j;
        break;
      }
    }
    if (i < 0) break;
    const [a, b] = out[i]!;
    const mid = (a + b) / 2;
    out.splice(i, 1, [a, mid], [mid, b]);
  }
  return out;
}

/** Number of complete blocks of `size` in a log of T entries. */
const complete = (T: number, size: number) => Math.floor(T / size);

/**
 * Blocks that can be built and are not, smallest size first. `built(size)` is
 * how many blocks of that size exist; each level is a dense prefix.
 */
export function pending(T: number, built: (size: number) => number, limit?: number): Array<Block> {
  const todo: Array<Block> = [];
  for (let size = 2; size <= T; size *= 2) {
    for (let k = built(size); k < complete(T, size); k++) {
      todo.push([k * size, (k + 1) * size]);
      if (limit !== undefined && todo.length >= limit) return todo;
    }
  }
  return todo;
}

/** How many blocks `pending` would list. A level may hold more than T needs (T is a snapshot). */
export function pendingCount(T: number, built: (size: number) => number): number {
  let n = 0;
  for (let size = 2; size <= T; size *= 2) n += Math.max(0, complete(T, size) - built(size));
  return n;
}

/** Parses an inclusive id `lo-hi` into a half-open block, or says why it is not one. */
export function parseBlock(id: string): Block | "not_an_id" | "not_a_block" {
  const m = /^(\d+)-(\d+)$/.exec(id);
  if (!m) return "not_an_id";
  const lo = Number(m[1]);
  const hi = Number(m[2]) + 1;
  const n = hi - lo;
  if (n < 2 || (n & (n - 1)) !== 0 || lo % n !== 0) return "not_a_block";
  return [lo, hi];
}

/** `lo-hi`, inclusive, as wake prints it. */
export const blockId = ([lo, hi]: Block) => `${lo}-${hi - 1}`;
