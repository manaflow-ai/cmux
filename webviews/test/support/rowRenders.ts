// Counts which components rendered in each React commit, by component name, with no
// instrumentation in the list under test: a DevTools hook sees every commit, and a function
// component rendered in it when its props or its hook list is a new object (a memo bail-out keeps
// both). test/preload.ts loads React DOM before any test file runs, so a hook installed by a file
// is never seen by that copy: `createRoot` here is a fresh copy of the React DOM client, loaded
// after the hook is in place. Mount the list with it, `reset()`, make one change, read `count`.
//
// The rule it backs: when one item changes, the list scrolls a row, a sibling is hovered or
// selected or a clock ticks, rows whose data did not change render 0 times.
import { fileURLToPath } from "node:url";

type Fiber = {
  tag: number;
  type: unknown;
  child: Fiber | null;
  sibling: Fiber | null;
  memoizedProps: unknown;
  memoizedState: unknown;
};

// FunctionComponent, ForwardRef, SimpleMemoComponent: the tags whose own function runs.
const FUNCTION_TAGS = new Set([0, 11, 15]);

const counts = new Map<string, number>();
let seen = new WeakSet<object>();

const nameOf = (type: unknown): string | undefined => {
  if (typeof type === "function") return (type as { displayName?: string; name?: string }).displayName ?? type.name;
  const inner = (type as { render?: unknown; type?: unknown } | null)?.render;
  return inner ? nameOf(inner) : undefined;
};

function walk(fiber: Fiber | null): void {
  for (let node = fiber; node; node = node.sibling) {
    if (FUNCTION_TAGS.has(node.tag)) {
      const props = node.memoizedProps as object | null;
      const state = node.memoizedState as object | null;
      const fresh =
        (props !== null && typeof props === "object" && !seen.has(props)) ||
        (state !== null && typeof state === "object" && !seen.has(state));
      if (props && typeof props === "object") seen.add(props);
      if (state && typeof state === "object") seen.add(state);
      const name = nameOf(node.type);
      if (fresh && name) counts.set(name, (counts.get(name) ?? 0) + 1);
    }
    walk(node.child);
  }
}

const scope = globalThis as Record<string, unknown>;
const previousHook = scope.__REACT_DEVTOOLS_GLOBAL_HOOK__;
scope.__REACT_DEVTOOLS_GLOBAL_HOOK__ = {
  isDisabled: false,
  supportsFiber: true,
  renderers: new Map(),
  inject: () => 1,
  checkDCE: () => {},
  onScheduleFiberRoot: () => {},
  onCommitFiberUnmount: () => {},
  onPostCommitFiberRoot: () => {},
  onCommitFiberRoot: (_id: number, root: { current: Fiber }) => walk(root.current),
};

const build = process.env.NODE_ENV === "production" ? "production" : "development";
const clientPath = fileURLToPath(
  new URL(`./cjs/react-dom-client.${build}.js`, import.meta.resolve("react-dom/client")),
);
delete require.cache[clientPath];
const client = require(clientPath) as typeof import("react-dom/client");
// Later loads of the client get the shared copy again; only roots made here are counted.
delete require.cache[clientPath];
if (previousHook === undefined) delete scope.__REACT_DEVTOOLS_GLOBAL_HOOK__;
else scope.__REACT_DEVTOOLS_GLOBAL_HOOK__ = previousHook;

/** A root on the counted copy of React DOM. */
export const createRoot: typeof client.createRoot = client.createRoot;

export const rowRenders = {
  /** Forget earlier counts; components mounted so far count from their next render. */
  reset() {
    counts.clear();
  },
  /** Renders of the named component since the last `reset`. */
  count(name: string): number {
    return counts.get(name) ?? 0;
  },
  /** Every component that rendered since the last `reset`, by name. */
  all(): Record<string, number> {
    return Object.fromEntries(counts);
  },
  /** Start over completely (a new mount treats every component as fresh again). */
  clear() {
    counts.clear();
    seen = new WeakSet();
  },
};
