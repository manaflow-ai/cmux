/**
 * An immutable prefix-sum index for transcript row heights.
 *
 * Rows are grouped into small leaves so a drawn-height correction copies one
 * leaf and the logarithmic path to that leaf.  The previous index is never
 * mutated, which lets the anchor code compare two layouts while a new one is
 * being prepared.
 */

const BLOCK_SIZE = 64;

// Layout geometry is monotone and finite. Invalid measurements are treated as
// a zero-height row, preserving their position in the transcript.
function normalizeHeight(value: number): number {
  return Number.isFinite(value) && value >= 0 ? value : 0;
}

type Leaf = {
  readonly values: Float64Array;
  readonly sum: number;
};

type Node = {
  readonly sum: number;
  readonly left?: Node;
  readonly right?: Node;
  readonly leaf?: Leaf;
};

function nodeSum(node: Node | undefined): number {
  return node?.sum ?? 0;
}

function makeLeaf(values: ArrayLike<number>, start: number, count: number): Leaf {
  const copied = new Float64Array(count);
  let sum = 0;
  for (let index = 0; index < count; index += 1) {
    const value = normalizeHeight(values[start + index] ?? 0);
    copied[index] = value;
    sum += value;
  }
  return { values: copied, sum };
}

function makeTree(leaves: readonly Leaf[], low: number, high: number): Node | undefined {
  if (low >= high) return undefined;
  if (high - low === 1) {
    const leaf = leaves[low];
    return leaf ? { leaf, sum: leaf.sum } : undefined;
  }
  const middle = low + ((high - low) >>> 1);
  const left = makeTree(leaves, low, middle);
  const right = makeTree(leaves, middle, high);
  return { left, right, sum: nodeSum(left) + nodeSum(right) };
}

function updateLeaf(
  node: Node | undefined,
  low: number,
  high: number,
  leafIndex: number,
  offset: number,
  value: number,
): Node | undefined {
  if (low >= high) return node;
  if (high - low === 1) {
    const previous = node?.leaf;
    if (!previous) return node;
    if (previous.values[offset] === value) return node;
    const values = Float64Array.from(previous.values);
    values[offset] = value;
    // Re-sum the copied bounded leaf instead of subtracting floating-point
    // values from the old aggregate. Repeated 0.1/0.2 corrections must settle
    // exactly when all entries become zero.
    let sum = 0;
    for (const entry of values) sum += entry;
    const leaf = { values, sum };
    return { leaf, sum: leaf.sum };
  }
  const middle = low + ((high - low) >>> 1);
  const left = leafIndex < middle ? updateLeaf(node?.left, low, middle, leafIndex, offset, value) : node?.left;
  const right = leafIndex >= middle ? updateLeaf(node?.right, middle, high, leafIndex, offset, value) : node?.right;
  return { left, right, sum: nodeSum(left) + nodeSum(right) };
}

function readLeaf(node: Node | undefined, low: number, high: number, leafIndex: number): Leaf | undefined {
  if (!node || low >= high) return undefined;
  if (high - low === 1) return node.leaf;
  const middle = low + ((high - low) >>> 1);
  return leafIndex < middle
    ? readLeaf(node.left, low, middle, leafIndex)
    : readLeaf(node.right, middle, high, leafIndex);
}

function prefixBeforeLeaf(node: Node | undefined, low: number, high: number, leafIndex: number): number {
  if (!node || low >= high || leafIndex <= low) return 0;
  if (high - low === 1) return node.sum;
  const middle = low + ((high - low) >>> 1);
  if (leafIndex <= middle) return prefixBeforeLeaf(node.left, low, middle, leafIndex);
  return nodeSum(node.left) + prefixBeforeLeaf(node.right, middle, high, leafIndex);
}

/**
 * Immutable row-height prefix sums. `update` and `append` share untouched
 * tree nodes with their input; they never retain a reference to an entire
 * previous snapshot or mutate a shared leaf.
 */
export class PlacedHeightIndex {
  readonly count: number;
  readonly totalHeight: number;

  private constructor(
    count: number,
    private readonly capacity: number,
    private readonly root: Node | undefined,
  ) {
    this.count = count;
    this.totalHeight = nodeSum(root);
  }

  static empty(): PlacedHeightIndex {
    return new PlacedHeightIndex(0, 1, undefined);
  }

  static fromHeights(values: ArrayLike<number>): PlacedHeightIndex {
    const count = values.length;
    const blockCount = Math.max(1, Math.ceil(count / BLOCK_SIZE));
    let capacity = 1;
    while (capacity < blockCount) capacity <<= 1;
    const leaves: Leaf[] = [];
    for (let start = 0; start < count; start += BLOCK_SIZE)
      leaves.push(makeLeaf(values, start, Math.min(BLOCK_SIZE, count - start)));
    return new PlacedHeightIndex(count, capacity, makeTree(leaves, 0, capacity));
  }

  heightAt(index: number): number {
    if (!Number.isInteger(index) || index < 0 || index >= this.count) return 0;
    const leaf = readLeaf(this.root, 0, this.capacity, Math.floor(index / BLOCK_SIZE));
    return leaf?.values[index % BLOCK_SIZE] ?? 0;
  }

  topAt(index: number): number {
    if (!Number.isInteger(index) || index <= 0) return 0;
    if (index >= this.count) return this.totalHeight;
    const leafIndex = Math.floor(index / BLOCK_SIZE);
    const leaf = readLeaf(this.root, 0, this.capacity, leafIndex);
    let sum = prefixBeforeLeaf(this.root, 0, this.capacity, leafIndex);
    for (let offset = 0; offset < index % BLOCK_SIZE; offset += 1) sum += leaf?.values[offset] ?? 0;
    return sum;
  }

  /** Returns a new index with one row's height replaced. */
  update(index: number, value: number): PlacedHeightIndex {
    if (!Number.isInteger(index) || index < 0 || index >= this.count || !Number.isFinite(value) || value < 0)
      return this;
    const previous = this.heightAt(index);
    if (previous === value) return this;
    const leafIndex = Math.floor(index / BLOCK_SIZE);
    const root = updateLeaf(this.root, 0, this.capacity, leafIndex, index % BLOCK_SIZE, value);
    return new PlacedHeightIndex(this.count, this.capacity, root);
  }

  /** Returns a new index with the supplied rows appended. */
  append(values: ArrayLike<number>): PlacedHeightIndex {
    if (values.length === 0) return this;
    let next: PlacedHeightIndex | undefined;
    for (let index = 0; index < values.length; index += 1) {
      const base = next ?? this;
      const rowIndex = base.count;
      const value = normalizeHeight(values[index] ?? 0);
      next = base.appendOne(rowIndex, value);
    }
    return next ?? this;
  }

  private appendOne(index: number, value: number): PlacedHeightIndex {
    const leafIndex = Math.floor(index / BLOCK_SIZE);
    let capacity = this.capacity;
    let root = this.root;
    if (leafIndex >= capacity) {
      while (leafIndex >= capacity) {
        root = { left: root, sum: nodeSum(root) };
        capacity <<= 1;
      }
    }
    const offset = index % BLOCK_SIZE;
    const previous = readLeaf(root, 0, capacity, leafIndex);
    const valueCount = Math.min(BLOCK_SIZE, index + 1 - leafIndex * BLOCK_SIZE);
    const values = new Float64Array(Math.max(previous?.values.length ?? 0, valueCount));
    if (previous) values.set(previous.values);
    const old = values[offset] ?? 0;
    values[offset] = value;
    const leaf = { values, sum: previous ? previous.sum + value - old : value };
    // A freshly appended row can only land in the rightmost leaf. Rebuilding
    // that path keeps every untouched block shared with the old snapshot.
    const replace = (node: Node | undefined, low: number, high: number): Node | undefined => {
      if (high - low === 1) return { leaf, sum: leaf.sum };
      const middle = low + ((high - low) >>> 1);
      const left = leafIndex < middle ? replace(node?.left, low, middle) : node?.left;
      const right = leafIndex >= middle ? replace(node?.right, middle, high) : node?.right;
      return { left, right, sum: nodeSum(left) + nodeSum(right) };
    };
    root = replace(root, 0, capacity);
    return new PlacedHeightIndex(index + 1, capacity, root);
  }

  /** Finds the first row whose top is greater than `target` (upper-bound semantics). */
  upperBoundTop(target: number): number {
    let low = 0;
    let high = this.count;
    while (low < high) {
      const middle = (low + high) >>> 1;
      if (this.topAt(middle) <= target) low = middle + 1;
      else high = middle;
    }
    return low;
  }

  /** Explicitly materializes a compatibility array for consumers that need one. */
  materializeHeights(): Float64Array {
    const values = new Float64Array(this.count);
    for (let index = 0; index < this.count; index += 1) values[index] = this.heightAt(index);
    return values;
  }

  /** Explicitly materializes row tops for legacy consumers. */
  materializeTops(): Float64Array {
    const values = new Float64Array(this.count);
    let top = 0;
    for (let index = 0; index < this.count; index += 1) {
      values[index] = top;
      top += this.heightAt(index);
    }
    return values;
  }
}

export const PLACED_HEIGHT_BLOCK_SIZE = BLOCK_SIZE;
