// Counts React renders by component name from the DevTools commit hook, with no instrumentation in
// the list under test: imported before react-dom, which then reports every commit here. A fiber
// rendered in a commit when it was mounted (no alternate) or its PerformedWork flag is set; a
// subtree whose child pointer is its alternate's was not cloned (nothing in it ran) and is skipped,
// as React DevTools does. Off by default: a timed step must not pay for the walk.

interface Fiber {
  tag: number;
  type: unknown;
  flags: number;
  child: Fiber | null;
  sibling: Fiber | null;
  alternate: Fiber | null;
}

const PERFORMED_WORK = 1;
// Function, class, forwardRef and simple memo components; a memo with a comparator (14) renders
// its inner function as a child fiber (0), which is the one counted.
const COMPONENT_TAGS = new Set([0, 1, 11, 15]);

const renders = new Map<string, number>();
const mounts = new Map<string, number>();
let counting = false;

function nameOf(type: unknown): string {
  if (typeof type === "function") return (type as { displayName?: string }).displayName ?? type.name ?? "";
  const inner = type as { displayName?: string; render?: { name?: string }; type?: unknown } | null;
  return inner?.displayName ?? inner?.render?.name ?? (inner?.type ? nameOf(inner.type) : "");
}

function walk(root: Fiber) {
  const stack: Fiber[] = [root];
  while (stack.length) {
    const fiber = stack.pop()!;
    if (COMPONENT_TAGS.has(fiber.tag)) {
      const name = nameOf(fiber.type);
      if (fiber.alternate === null) mounts.set(name, (mounts.get(name) ?? 0) + 1);
      if (fiber.alternate === null || fiber.flags & PERFORMED_WORK) renders.set(name, (renders.get(name) ?? 0) + 1);
    }
    if (fiber.alternate && fiber.child === fiber.alternate.child) continue;
    for (let child = fiber.child; child; child = child.sibling) stack.push(child);
  }
}

(window as unknown as { __REACT_DEVTOOLS_GLOBAL_HOOK__: unknown }).__REACT_DEVTOOLS_GLOBAL_HOOK__ = {
  supportsFiber: true,
  isDisabled: false,
  renderers: new Map(),
  inject: () => 1,
  checkDCE: () => {},
  onScheduleFiberRoot: () => {},
  onCommitFiberUnmount: () => {},
  onPostCommitFiberRoot: () => {},
  onCommitFiberRoot: (_id: number, root: { current: Fiber }) => {
    if (counting) walk(root.current);
  },
};

export const renderCounts = {
  start() {
    renders.clear();
    mounts.clear();
    counting = true;
  },
  stop() {
    counting = false;
  },
  /** Renders (mounts included) and mounts since `start` of the named components: the largest
   * count among them, since a row is one render of each (a row and the content it draws). */
  read(names: readonly string[]) {
    const most = (map: Map<string, number>) => Math.max(0, ...names.map((name) => map.get(name) ?? 0));
    return { renders: most(renders), mounts: most(mounts) };
  },
};
