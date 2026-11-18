// Which rows of a list rendered, from React's commit hook, with nothing added to the rows. React
// reads `__REACT_DEVTOOLS_GLOBAL_HOOK__` once, when react-dom loads, so the hook must be in place
// before that: test/preload.ts installs it for the default suite (jsdom files), and the list
// contract (listContract.ts) installs it in each browser page with `page.addInitScript`. One walker
// serves both, so a jsdom test and the browser contract count the same thing.
//
// Each commit, every component fiber that did work, and every host element whose props changed, is
// charged to the row its DOM sits in (`rows` matched by `closest`, inside `within`); a component
// that renders one row's element and nothing else is charged to that row. A row rendered for
// nothing when its `outerHTML` is the same after as before.
//
//   const renders = rowRenders();
//   renders.begin(container, ".foo-row");
//   act(() => store.update(one));
//   expect(renders.end()).toMatchObject({ rerendered: 1, wasted: 0 });

export type RowRenderCount = {
  /// Rows mounted at `begin` that rendered since.
  rerendered: number;
  /// Of those, rows whose DOM is the same: renders for nothing.
  wasted: number;
  /// Rows mounted since `begin`.
  added: number;
  /// The most commits any one row rendered in.
  maxRenders: number;
};

export type RowRenderCounter = {
  begin(within: Element, rows: string): void;
  end(): RowRenderCount;
};

/**
 * Installs the commit hook (wrapping one already there) and `globalThis.__cmuxRowRenders`. Must run
 * before react-dom loads. Self-contained: Playwright serializes it into a page.
 */
export function installRowRenderCounter() {
  type Fiber = {
    tag: number;
    flags: number;
    child: Fiber | null;
    sibling: Fiber | null;
    return: Fiber | null;
    alternate: Fiber | null;
    memoizedProps: unknown;
    stateNode: unknown;
  };
  type Hook = Record<string, unknown> & { onCommitFiberRoot?: (...args: unknown[]) => unknown };
  const scope = globalThis as unknown as { __REACT_DEVTOOLS_GLOBAL_HOOK__?: Hook; __cmuxRowRenders?: unknown };
  if (scope.__cmuxRowRenders) return;
  // FunctionComponent, ClassComponent, ForwardRef, MemoComponent, SimpleMemoComponent.
  const COMPONENT = new Set([0, 1, 11, 14, 15]);
  // HostComponent, HostHoistable, HostSingleton.
  const HOST = new Set([5, 26, 27]);
  const PORTAL = 4;
  const PERFORMED_WORK = 1;
  let counting = false;
  let rowSelector = "";
  let within: Element | null = null;
  let before = new Map<Element, string>();
  let renders = new Map<Element, number>();
  let touched = new Set<Element>();

  // Duck-typed: a jsdom file's Element is not this realm's.
  const rowOf = (node: unknown): Element | null => {
    if (!within || typeof (node as Element | null)?.closest !== "function") return null;
    const row = (node as Element).closest(rowSelector);
    return row && within.contains(row) ? row : null;
  };
  const hostAbove = (fiber: Fiber): unknown => {
    for (let at = fiber.return; at; at = at.return) if (HOST.has(at.tag)) return at.stateNode;
    return null;
  };
  /// The host elements a component renders at its top level (up to two).
  const hostsBelow = (fiber: Fiber, found: unknown[] = []): unknown[] => {
    for (let child = fiber.child; child && found.length < 2; child = child.sibling) {
      if (HOST.has(child.tag)) found.push(child.stateNode);
      else if (child.tag !== PORTAL) hostsBelow(child, found);
    }
    return found;
  };
  const charge = (fiber: Fiber) => {
    let row = HOST.has(fiber.tag) ? rowOf(fiber.stateNode) : rowOf(hostAbove(fiber));
    if (!row && COMPONENT.has(fiber.tag)) {
      const hosts = hostsBelow(fiber);
      if (hosts.length === 1) row = rowOf(hosts[0]);
    }
    if (row) touched.add(row);
  };
  const rendered = (next: Fiber, prev: Fiber) =>
    COMPONENT.has(next.tag)
      ? (next.flags & PERFORMED_WORK) === PERFORMED_WORK
      : HOST.has(next.tag) && next.memoizedProps !== prev.memoizedProps;
  const mounted = (fiber: Fiber) => {
    if (COMPONENT.has(fiber.tag) || HOST.has(fiber.tag)) charge(fiber);
    for (let child = fiber.child; child; child = child.sibling) mounted(child);
  };
  // React DevTools' walk: a subtree whose child pointer did not move did not render.
  const updated = (next: Fiber, prev: Fiber) => {
    if (rendered(next, prev)) charge(next);
    if (next.child === prev.child) return;
    for (let child = next.child; child; child = child.sibling)
      if (child.alternate) updated(child, child.alternate);
      else mounted(child);
  };
  const onCommit = (root: { current?: Fiber } | undefined) => {
    const current = root?.current;
    if (!counting || !current) return;
    touched = new Set();
    if (current.alternate) updated(current, current.alternate);
    else mounted(current);
    for (const row of touched) renders.set(row, (renders.get(row) ?? 0) + 1);
  };

  const existing = scope.__REACT_DEVTOOLS_GLOBAL_HOOK__;
  if (existing) {
    const theirs = existing.onCommitFiberRoot;
    existing.onCommitFiberRoot = (...args: unknown[]) => {
      onCommit(args[1] as { current?: Fiber });
      return theirs?.apply(existing, args);
    };
  } else {
    const renderers = new Map<number, unknown>();
    scope.__REACT_DEVTOOLS_GLOBAL_HOOK__ = {
      renderers,
      supportsFiber: true,
      inject(renderer: unknown) {
        renderers.set(renderers.size + 1, renderer);
        return renderers.size;
      },
      onScheduleFiberRoot() {},
      onCommitFiberUnmount() {},
      onPostCommitFiberRoot() {},
      checkDCE() {},
      onCommitFiberRoot: (_id: unknown, root: unknown) => onCommit(root as { current?: Fiber }),
    };
  }

  const counter: RowRenderCounter = {
    begin(element, rows) {
      within = element;
      rowSelector = rows;
      before = new Map([...element.querySelectorAll(rows)].map((row) => [row, row.outerHTML]));
      renders = new Map();
      counting = true;
    },
    end() {
      counting = false;
      let rerendered = 0;
      let wasted = 0;
      let added = 0;
      for (const row of renders.keys()) {
        const html = before.get(row);
        if (html === undefined) added++;
        else {
          rerendered++;
          if (row.isConnected && row.outerHTML === html) wasted++;
        }
      }
      return { rerendered, wasted, added, maxRenders: Math.max(0, ...renders.values()) };
    },
  };
  scope.__cmuxRowRenders = counter;
}

/** The counter test/preload.ts installed before react-dom loaded. */
export function rowRenders(): RowRenderCounter {
  const counter = (globalThis as { __cmuxRowRenders?: RowRenderCounter }).__cmuxRowRenders;
  if (!counter) throw new Error("rowRenders: no commit hook; test/preload.ts installs it before react-dom loads");
  return counter;
}
