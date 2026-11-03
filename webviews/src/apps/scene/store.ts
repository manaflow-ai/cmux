import { useSyncExternalStore } from "react";

export type SceneProps = Record<string, unknown>;
export type SceneNode = { id: string; type: string; props: SceneProps; children: string[] };
export type SceneOp =
  | { op: "create"; id: string; type: string; props?: SceneProps | null }
  | { op: "update"; id: string; props?: SceneProps | null }
  | { op: "children"; id: string; children: string[] }
  | { op: "remove"; id: string }
  | { op: "root"; id: string };

const MAX_NODES = 4096;
const MAX_DEPTH = 64;

export class SceneStore {
  private nodes = new Map<string, SceneNode>();
  private parents = new Map<string, string>();
  private root: string | undefined;
  private listeners = new Set<() => void>();
  private version = 0;

  getNode(id: string): SceneNode | undefined { return this.nodes.get(id); }
  getRoot(): string | undefined { return this.root; }
  getVersion(): number { return this.version; }
  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  apply(ops: readonly SceneOp[], reset = false): void {
    if (reset) {
      this.nodes.clear();
      this.parents.clear();
      this.root = undefined;
    }
    for (const op of ops) this.applyOne(op);
    this.version += 1;
    for (const listener of this.listeners) listener();
  }

  private applyOne(op: SceneOp): void {
    if (op.op === "create") {
      if (!op.id || this.nodes.has(op.id) || this.nodes.size >= MAX_NODES) return;
      this.nodes.set(op.id, { id: op.id, type: op.type, props: { ...(op.props ?? {}) }, children: [] });
      return;
    }
    if (op.op === "update") {
      const node = this.nodes.get(op.id);
      if (!node) return;
      for (const [key, value] of Object.entries(op.props ?? {})) {
        if (value === null) delete node.props[key];
        else node.props[key] = value;
      }
      return;
    }
    if (op.op === "children") {
      const node = this.nodes.get(op.id);
      if (!node) return;
      const children: string[] = [];
      for (const child of op.children) {
        if (child === op.id || children.includes(child) || !this.nodes.has(child)) continue;
        if (this.depthIf(node.id, child) > MAX_DEPTH) continue;
        children.push(child);
      }
      for (const old of node.children) if (!children.includes(old) && this.parents.get(old) === node.id) this.parents.delete(old);
      for (const child of children) {
        const previous = this.parents.get(child);
        if (previous && previous !== node.id) {
          const parent = this.nodes.get(previous);
          if (parent) parent.children = parent.children.filter((id) => id !== child);
        }
        this.parents.set(child, node.id);
      }
      node.children = children;
      return;
    }
    if (op.op === "remove") {
      this.remove(op.id);
      return;
    }
    if (op.op === "root" && this.nodes.has(op.id)) this.root = op.id;
  }

  private depthIf(parent: string, child: string): number {
    let depth = 1;
    let current: string | undefined = parent;
    while (current) {
      if (current === child) return MAX_DEPTH + 1;
      current = this.parents.get(current);
      depth += 1;
    }
    return depth;
  }

  private remove(id: string): void {
    if (!this.nodes.has(id)) return;
    const parent = this.parents.get(id);
    const owner = parent ? this.nodes.get(parent) : undefined;
    const stack = [id];
    while (stack.length) {
      const current = stack.pop()!;
      const node = this.nodes.get(current);
      if (!node) continue;
      stack.push(...node.children);
      this.nodes.delete(current);
      this.parents.delete(current);
      if (this.root === current) this.root = undefined;
    }
    if (owner) owner.children = owner.children.filter((child) => child !== id);
  }
}

export function useSceneVersion(store: SceneStore): number {
  return useSyncExternalStore(store.subscribe, () => store.getVersion(), () => store.getVersion());
}
