// Counts React renders from the DevTools commit hook, with no instrumentation in the list under
// test: imported before react-dom, which then reports every commit here. Off by default: a timed
// step must not pay for the walk.
//
// A component fiber rendered in a commit when it was mounted (no alternate) or its PerformedWork
// flag is set; a host element fiber was redrawn when it was mounted or its props are a new object
// (the JSX that made it ran again: an inline row a parent maps). A subtree whose child pointer is
// its alternate's was not cloned (nothing in it ran) and is skipped, as React DevTools does.
//
// Rows (`rows`): a row is an element matching the case's row selector inside its list. A row
// rendered in a commit when any fiber that did work has its host output inside it: a redrawn host
// element itself, or a component's nearest host nodes when they fall in that one row (a component
// whose output spans several rows, a collection that maps them, is the list's, not a row's). Each
// row counts once per commit, whatever draws it (a named row component, inline JSX, a row
// re-rendering from its own hooks). The rows are resolved when read, so a count taken across a
// case's mount (before its selector is known) works.
//
// Names (`read`): the renders of the named components, for a breakdown by component. A row drawn
// by an inline arrow or unnamed JSX has no name and counts 0 there, so the headline is `rows`.

interface Fiber {
  tag: number;
  type: unknown;
  flags: number;
  child: Fiber | null;
  sibling: Fiber | null;
  alternate: Fiber | null;
  memoizedProps: unknown;
  stateNode: unknown;
}

const PERFORMED_WORK = 1;
// Function, class, forwardRef and simple memo components; a memo with a comparator (14) renders
// its inner function as a child fiber (0), which is the one counted.
const COMPONENT_TAGS = new Set([0, 1, 11, 15]);
// Host elements (HostComponent, HostHoistable, HostSingleton) and host text.
const HOST_ELEMENT_TAGS = new Set([5, 26, 27]);
const HOST_TEXT = 6;

const renders = new Map<string, number>();
const mounts = new Map<string, number>();
/** Per commit: the host elements redrawn, each rendered component's nearest host nodes, and the
 * host elements mounted. */
const commits: { drawn: Set<Node>; components: Node[][]; mounted: Set<Element> }[] = [];
let counting = false;

function nameOf(type: unknown): string {
  if (typeof type === "function") return (type as { displayName?: string }).displayName ?? type.name ?? "";
  const inner = type as { displayName?: string; render?: { name?: string }; type?: unknown } | null;
  return inner?.displayName ?? inner?.render?.name ?? (inner?.type ? nameOf(inner.type) : "");
}

/** A component's nearest host nodes: the first host element or text on each path down from it. */
function hostOutput(fiber: Fiber): Node[] {
  const into: Node[] = [];
  const stack: Fiber[] = [];
  for (let child = fiber.child; child; child = child.sibling) stack.push(child);
  while (stack.length) {
    const next = stack.pop()!;
    if (HOST_ELEMENT_TAGS.has(next.tag) || next.tag === HOST_TEXT) {
      if (next.stateNode instanceof Node) into.push(next.stateNode);
      continue;
    }
    for (let child = next.child; child; child = child.sibling) stack.push(child);
  }
  return into;
}

function walk(root: Fiber) {
  const drawn = new Set<Node>();
  const components: Node[][] = [];
  const mounted = new Set<Element>();
  const stack: Fiber[] = [root];
  while (stack.length) {
    const fiber = stack.pop()!;
    const fresh = fiber.alternate === null;
    if (COMPONENT_TAGS.has(fiber.tag)) {
      const name = nameOf(fiber.type);
      if (fresh) mounts.set(name, (mounts.get(name) ?? 0) + 1);
      if (fresh || fiber.flags & PERFORMED_WORK) {
        renders.set(name, (renders.get(name) ?? 0) + 1);
        const output = hostOutput(fiber);
        if (output.length) components.push(output);
      }
    } else if (HOST_ELEMENT_TAGS.has(fiber.tag) && fiber.stateNode instanceof Element) {
      if (fresh) mounted.add(fiber.stateNode);
      if (fresh || fiber.memoizedProps !== fiber.alternate!.memoizedProps) drawn.add(fiber.stateNode);
    }
    if (fiber.alternate && fiber.child === fiber.alternate.child) continue;
    for (let child = fiber.child; child; child = child.sibling) stack.push(child);
  }
  if (drawn.size || components.length || mounted.size) commits.push({ drawn, components, mounted });
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

/** The row (an element matching `selector` inside `list`) that holds `node`, if any. A row removed
 * since the commit that drew it still counts: it was mounted when it rendered. */
function rowOf(node: Node, selector: string, list: Element): Element | null {
  const element = node instanceof Element ? node : node.parentElement;
  const row = element?.closest(selector) ?? null;
  if (!row) return null;
  return list.contains(row) || !row.isConnected ? row : null;
}

export const renderCounts = {
  start() {
    renders.clear();
    mounts.clear();
    commits.length = 0;
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
  /** Row renders since `start`: in each commit, the rows (`selector` inside `list`) that a fiber
   * which did work drew into, each once, summed over the commits; row mounts likewise; and the most
   * of each in any one commit. */
  rows(selector: string, list: Element) {
    let rendered = 0;
    let mountedRows = 0;
    let peakRenders = 0;
    let peakMounts = 0;
    for (const commit of commits) {
      const rows = new Set<Element>();
      for (const node of commit.drawn) {
        const row = rowOf(node, selector, list);
        if (row) rows.add(row);
      }
      for (const output of commit.components) {
        const within = new Set<Element>();
        for (const node of output) {
          const row = rowOf(node, selector, list);
          if (row) within.add(row);
        }
        if (within.size === 1) rows.add(within.values().next().value!);
      }
      let fresh = 0;
      for (const element of commit.mounted) if (element.matches(selector) && rowOf(element, selector, list)) fresh++;
      rendered += rows.size;
      mountedRows += fresh;
      peakRenders = Math.max(peakRenders, rows.size);
      peakMounts = Math.max(peakMounts, fresh);
    }
    return { renders: rendered, mounts: mountedRows, peakRenders, peakMounts };
  },
};
