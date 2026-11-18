// Counts React renders by component name from the DevTools commit hook, with no instrumentation in
// the list under test: imported before react-dom, which then reports every commit here. A fiber
// rendered in a commit when it was mounted (no alternate) or its PerformedWork flag is set; a
// subtree whose child pointer is its alternate's was not cloned (nothing in it ran) and is skipped,
// as React DevTools does. Off by default: a timed step must not pay for the walk. Each name's
// largest count in any one commit is kept too, so a list that mounts every row for one commit and
// then windows them shows it.

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
const peakRenders = new Map<string, number>();
const peakMounts = new Map<string, number>();
let counting = false;

function nameOf(type: unknown): string {
  if (typeof type === "function") return (type as { displayName?: string }).displayName ?? type.name ?? "";
  const inner = type as { displayName?: string; render?: { name?: string }; type?: unknown } | null;
  return inner?.displayName ?? inner?.render?.name ?? (inner?.type ? nameOf(inner.type) : "");
}

function walk(root: Fiber) {
  const commitRenders = new Map<string, number>();
  const commitMounts = new Map<string, number>();
  const stack: Fiber[] = [root];
  while (stack.length) {
    const fiber = stack.pop()!;
    if (COMPONENT_TAGS.has(fiber.tag)) {
      const name = nameOf(fiber.type);
      if (fiber.alternate === null) commitMounts.set(name, (commitMounts.get(name) ?? 0) + 1);
      if (fiber.alternate === null || fiber.flags & PERFORMED_WORK)
        commitRenders.set(name, (commitRenders.get(name) ?? 0) + 1);
    }
    if (fiber.alternate && fiber.child === fiber.alternate.child) continue;
    for (let child = fiber.child; child; child = child.sibling) stack.push(child);
  }
  const add = (total: Map<string, number>, peak: Map<string, number>, commit: Map<string, number>) => {
    for (const [name, count] of commit) {
      total.set(name, (total.get(name) ?? 0) + count);
      peak.set(name, Math.max(peak.get(name) ?? 0, count));
    }
  };
  add(renders, peakRenders, commitRenders);
  add(mounts, peakMounts, commitMounts);
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
    peakRenders.clear();
    peakMounts.clear();
    counting = true;
  },
  stop() {
    counting = false;
  },
  /** Renders (mounts included) and mounts since `start` of the named components: the largest
   * count among them, since a row is one render of each (a row and the content it draws).
   * `peakRenders` and `peakMounts` are the same in the one commit that had the most. */
  read(names: readonly string[]) {
    const most = (map: Map<string, number>) => Math.max(0, ...names.map((name) => map.get(name) ?? 0));
    return {
      renders: most(renders),
      mounts: most(mounts),
      peakRenders: most(peakRenders),
      peakMounts: most(peakMounts),
    };
  },
};
