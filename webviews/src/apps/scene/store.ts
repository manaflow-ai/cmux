export type SceneProps = Readonly<Record<string, unknown>>;
export type SceneNode = Readonly<{
  id: string;
  type: string;
  props: SceneProps;
  children: readonly string[];
}>;
/** A `transition` prop: a bare kind or `{kind, motion}` (cmux.motion/1). */
function hasTransition(value: unknown): boolean {
  if (typeof value === "string") return true;
  return typeof value === "object" && value !== null && typeof (value as { kind?: unknown }).kind === "string";
}

export type SceneOp =
  | { op: "create"; id: string; type: string; props?: SceneProps | null }
  | { op: "update"; id: string; props?: SceneProps | null }
  | { op: "children"; id: string; children: readonly string[] }
  | { op: "remove"; id: string }
  | { op: "root"; id: string };

/** A mount's state, as the host's `AppSceneModel.Status`: loading until its first scene has a root,
 * failed with the host's raw reason, or disconnected with the plain-words reason (the supervisor
 * is unreachable; the mount renders again after the reconnect). */
export type SceneStatus =
  | { state: "loading" }
  | { state: "ready" }
  | { state: "failed"; reason: string }
  | { state: "disconnected"; reason: string };
/** What moves a status: the host's forwarded status, a scene batch applied, or a reset scene. */
export type SceneStatusAction =
  | { type: "status"; status: unknown; reason?: unknown }
  | { type: "scene"; hasRoot: boolean }
  | { type: "reset" };

export const SCENE_LOADING: SceneStatus = Object.freeze({ state: "loading" });
const SCENE_READY: SceneStatus = Object.freeze({ state: "ready" });

/** The host model's transitions: a reset loads again, the first batch with a root makes a loading
 * mount ready (a failed or disconnected one stays until the host says otherwise), and a forwarded
 * status replaces the current one. An unknown or malformed forwarded status changes nothing. An
 * unchanged status returns the same object, so subscribers re-render only on a real change. */
export function sceneStatusReducer(current: SceneStatus, action: SceneStatusAction): SceneStatus {
  switch (action.type) {
    case "reset":
      return current.state === "loading" ? current : SCENE_LOADING;
    case "scene":
      return action.hasRoot && current.state === "loading" ? SCENE_READY : current;
    case "status": {
      const reason = typeof action.reason === "string" ? action.reason : "";
      switch (action.status) {
        case "loading":
          return current.state === "loading" ? current : SCENE_LOADING;
        case "ready":
          return current.state === "ready" ? current : SCENE_READY;
        case "failed":
        case "disconnected":
          return current.state === action.status && current.reason === reason
            ? current
            : { state: action.status, reason };
        default:
          return current;
      }
    }
  }
}

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
  // Counts resets: a reset scene is a new tree, so the renderer draws it fresh (no enter or leave
  // animation carried over from the old one).
  private generation = 0;
  // The generation whose first frame has committed (`SceneAppeared`): nodes created after it enter.
  private drawn = -1;
  // Removed nodes that leave with a `transition` (and their subtrees), as they last were: the
  // renderer draws them from here until they have left (sceneMotion.tsx).
  private readonly departed = new Map<string, SceneNode>();
  private readonly listeners = new Map<string, Set<Listener>>();
  private readonly rootListeners = new Set<Listener>();
  private status: SceneStatus = SCENE_LOADING;
  private readonly statusListeners = new Set<Listener>();

  getNode(id: string): SceneNode | undefined {
    return this.nodes.get(id);
  }
  getRoot = (): string | undefined => this.root;
  getGeneration = (): number => this.generation;
  markDrawn(generation: number): void {
    this.drawn = generation;
  }
  hasDrawn(): boolean {
    return this.drawn === this.generation;
  }
  getDeparted(id: string): SceneNode | undefined {
    return this.departed.get(id);
  }
  /** Drops a departed node and its departed subtree once it has left. */
  forgetDeparted(id: string): void {
    const stack = [id];
    while (stack.length) {
      const next = this.departed.get(stack.pop()!);
      if (!next) continue;
      this.departed.delete(next.id);
      stack.push(...next.children);
    }
  }

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

  getStatus = (): SceneStatus => this.status;
  subscribeStatus = (listener: Listener): (() => void) => {
    this.statusListeners.add(listener);
    return () => this.statusListeners.delete(listener);
  };

  /** Applies a host status event (`{status, reason?}` on the scene stream). */
  setStatus(status: unknown, reason?: unknown): void {
    this.reduceStatus({ type: "status", status, reason });
  }

  private reduceStatus(action: SceneStatusAction): void {
    this.publishStatus(sceneStatusReducer(this.status, action));
  }

  private publishStatus(next: SceneStatus): void {
    if (next === this.status) return;
    this.status = next;
    for (const listener of this.statusListeners) listener();
  }

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
      this.departed.clear();
      this.generation += 1;
    }
    for (const op of ops) this.applyOne(op, changed);
    for (const id of changed) {
      for (const listener of this.listeners.get(id) ?? []) listener();
    }
    if (reset || previousRoot !== this.root) for (const listener of this.rootListeners) listener();
    // After the scene's own listeners, as the host model sets its status after applying the batch.
    // A reset and its first root publish once: a failed mount whose new scene draws goes straight to ready.
    const status = reset ? sceneStatusReducer(this.status, { type: "reset" }) : this.status;
    this.publishStatus(sceneStatusReducer(status, { type: "scene", hasRoot: this.root !== undefined }));
  }

  /** The person typed in a TextField: the mirror's `text` is what the field shows, as the host's copy
   * is (it takes the text each edit, submit and cancel reports). So the app's next value replaces the
   * typed text whenever it differs from it, also when it equals the last value the host sent (an app
   * that sets "" after a submit while its value was "" all along), and an update of another prop
   * leaves the typed text alone. */
  reflectText(id: string, text: string): void {
    const node = this.nodes.get(id);
    if (!node || node.props.text === text) return;
    const changed = new Set<string>();
    this.write({ ...node, props: { ...node.props, text } }, changed);
    for (const listener of this.listeners.get(id) ?? []) listener();
  }

  private write(node: SceneNode, changed: Set<string>): void {
    this.nodes.set(node.id, node);
    changed.add(node.id);
  }

  private applyOne(op: SceneOp, changed: Set<string>): void {
    switch (op.op) {
      case "create": {
        if (!op.id || this.nodes.has(op.id) || this.nodes.size >= MAX_NODES) return;
        this.departed.delete(op.id);
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
        const leaves = hasTransition(this.nodes.get(op.id)?.props.transition);
        const stack = [op.id];
        while (stack.length) {
          const id = stack.pop()!;
          const node = this.nodes.get(id);
          if (!node) continue;
          stack.push(...node.children);
          if (leaves) this.keepDeparted(node);
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

  private keepDeparted(node: SceneNode): void {
    this.departed.delete(node.id);
    this.departed.set(node.id, node);
    // Bounded: the oldest go first (a leave lasts a fraction of a second).
    while (this.departed.size > MAX_NODES) {
      const oldest = this.departed.keys().next().value;
      if (oldest === undefined) break;
      this.departed.delete(oldest);
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
