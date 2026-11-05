export type SceneProps = Readonly<Record<string, unknown>>;
export type SceneNode = Readonly<{
  id: string;
  type: string;
  props: SceneProps;
  children: readonly string[];
}>;
export type SceneOp =
  | { op: "create"; id: string; type: string; props?: SceneProps | null }
  | { op: "update"; id: string; props?: SceneProps | null }
  | { op: "children"; id: string; children: readonly string[] }
  | { op: "remove"; id: string }
  | { op: "root"; id: string };

const MAX_NODES = 4096;
const MAX_DEPTH = 64;
type Listener = () => void;

/** One mount's scene mirror. Snapshots are immutable; a prop update notifies only that node.
 * Children ops visit only the changed branches, and batches publish their final state once. */
export class SceneStore {
  private readonly nodes = new Map<string, SceneNode>();
  private readonly parents = new Map<string, string>();
  private readonly heights = new Map<string, number>();
  // Height frequencies let one changed child update its ancestors without scanning their siblings.
  private readonly childHeights = new Map<string, Map<number, number>>();
  private root: string | undefined;
  private readonly listeners = new Map<string, Set<Listener>>();
  private readonly rootListeners = new Set<Listener>();

  getNode(id: string): SceneNode | undefined {
    return this.nodes.get(id);
  }
  getRoot = (): string | undefined => this.root;

  subscribeNode(id: string, listener: Listener): () => void {
    let listeners = this.listeners.get(id);
    if (!listeners) this.listeners.set(id, (listeners = new Set()));
    listeners.add(listener);
    return () => {
      listeners.delete(listener);
      if (!listeners.size) this.listeners.delete(id);
    };
  }

  subscribeRoot = (listener: Listener): (() => void) => {
    this.rootListeners.add(listener);
    return () => this.rootListeners.delete(listener);
  };

  apply(ops: readonly SceneOp[], reset = false): void {
    const previousRoot = this.root;
    const changed = new Set<string>();
    if (reset) {
      for (const id of this.nodes.keys()) changed.add(id);
      this.nodes.clear();
      this.parents.clear();
      this.heights.clear();
      this.childHeights.clear();
      this.root = undefined;
    }
    for (const op of ops) this.applyOne(op, changed);
    for (const id of changed) {
      for (const listener of this.listeners.get(id) ?? []) listener();
    }
    if (previousRoot !== this.root) for (const listener of this.rootListeners) listener();
  }

  private write(node: SceneNode, changed: Set<string>): void {
    this.nodes.set(node.id, node);
    changed.add(node.id);
  }

  private applyOne(op: SceneOp, changed: Set<string>): void {
    switch (op.op) {
      case "create": {
        if (!op.id || this.nodes.has(op.id) || this.nodes.size >= MAX_NODES) return;
        const props = Object.fromEntries(Object.entries(op.props ?? {}).filter(([, value]) => value !== null));
        this.write({ id: op.id, type: op.type, props, children: [] }, changed);
        this.heights.set(op.id, 1);
        return;
      }
      case "update": {
        const node = this.nodes.get(op.id);
        if (!node) return;
        const props = { ...node.props };
        let modified = false;
        for (const [key, value] of Object.entries(op.props ?? {})) {
          if (value === null) {
            if (Object.hasOwn(props, key)) {
              delete props[key];
              modified = true;
            }
          } else if (!Object.is(props[key], value)) {
            props[key] = value;
            modified = true;
          }
        }
        if (modified) this.write({ ...node, props }, changed);
        return;
      }
      case "children": {
        const node = this.nodes.get(op.id);
        if (!node) return;
        const seen = new Set<string>();
        const children = op.children.filter((id) => {
          if (seen.has(id) || id === op.id || !this.nodes.has(id) || this.isAncestor(id, op.id)) return false;
          seen.add(id);
          return true;
        });
        const depth = this.depth(op.id);
        if (children.some((id) => depth + (this.heights.get(id) ?? 1) > MAX_DEPTH)) return;
        if (children.length === node.children.length && children.every((id, index) => id === node.children[index]))
          return;
        for (const id of node.children) if (this.parents.get(id) === node.id) this.parents.delete(id);
        for (const id of children) {
          const previous = this.parents.get(id);
          if (previous && previous !== node.id) this.detach(id, previous, changed);
          this.parents.set(id, node.id);
        }
        this.write({ ...node, children }, changed);
        const heights = new Map<number, number>();
        for (const id of children) {
          const height = this.heights.get(id) ?? 1;
          heights.set(height, (heights.get(height) ?? 0) + 1);
        }
        this.childHeights.set(node.id, heights);
        this.refreshHeight(node.id);
        return;
      }
      case "remove": {
        const previous = this.parents.get(op.id);
        if (previous) this.detach(op.id, previous, changed);
        const stack = [op.id];
        while (stack.length) {
          const id = stack.pop()!;
          const node = this.nodes.get(id);
          if (!node) continue;
          stack.push(...node.children);
          this.nodes.delete(id);
          this.parents.delete(id);
          this.heights.delete(id);
          this.childHeights.delete(id);
          changed.add(id);
          if (this.root === id) this.root = undefined;
        }
        return;
      }
      case "root":
        if (this.nodes.has(op.id)) this.root = op.id;
    }
  }

  private detach(id: string, parentId: string, changed: Set<string>): void {
    const parent = this.nodes.get(parentId);
    if (parent) this.write({ ...parent, children: parent.children.filter((child) => child !== id) }, changed);
    this.parents.delete(id);
    this.adjustHeightCount(parentId, this.heights.get(id) ?? 1, -1);
    this.refreshHeight(parentId);
  }

  private isAncestor(candidate: string, id: string): boolean {
    let current = this.parents.get(id);
    while (current) {
      if (current === candidate) return true;
      current = this.parents.get(current);
    }
    return false;
  }

  private depth(id: string): number {
    let depth = 1;
    let current = this.parents.get(id);
    while (current) {
      depth++;
      current = this.parents.get(current);
    }
    return depth;
  }

  private adjustHeightCount(id: string, height: number, by: -1 | 1): void {
    let counts = this.childHeights.get(id);
    if (!counts) this.childHeights.set(id, (counts = new Map()));
    const count = (counts.get(height) ?? 0) + by;
    if (count <= 0) counts.delete(height);
    else counts.set(height, count);
  }

  /** At most 64 ancestors and 64 height buckets, independent of the number of descendant rows. */
  private refreshHeight(id: string): void {
    let current: string | undefined = id;
    while (current) {
      let next = 1;
      for (const height of this.childHeights.get(current)?.keys() ?? []) next = Math.max(next, height + 1);
      const before = this.heights.get(current) ?? 1;
      if (next === before) return;
      this.heights.set(current, next);
      const parent = this.parents.get(current);
      if (parent) {
        this.adjustHeightCount(parent, before, -1);
        this.adjustHeightCount(parent, next, 1);
      }
      current = parent;
    }
  }
}
