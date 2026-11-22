// Which React components rendered, by name, while a window was open: read off each commit the way
// React DevTools does (its renderer's `didFiberRender`). A commit's tree is walked only where it
// changed: a child list that is the same object as the previous commit's was not visited by React.
// Inside it a component counts when React performed work on it (the PerformedWork flag), so a
// memoized child React bailed out of does not count, nor does an element a compiled parent cached.
// A newly mounted component counts as a render.
//
// Install before the page's own code (`addInitScript`): React finds the hook as it loads. Then
// `start(page)` and `stop(page)` around the window; `stop` returns renders per component name.
import type { Page } from "playwright";

type FiberRenderWindow = Window & {
  __fiberRenders?: { on: boolean; counts: Record<string, number>; commits: number };
};

function defineFiberRenders() {
  const state = { on: false, counts: {} as Record<string, number>, commits: 0 };
  (window as FiberRenderWindow).__fiberRenders = state;
  // FunctionComponent, ClassComponent, ForwardRef, MemoComponent, SimpleMemoComponent.
  const COMPONENT = new Set([0, 1, 11, 14, 15]);
  const PERFORMED_WORK = 1;
  type Fiber = {
    tag: number;
    type: any;
    flags: number;
    child: Fiber | null;
    sibling: Fiber | null;
    alternate: Fiber | null;
  };
  const nameOf = (fiber: Fiber) => {
    const type = fiber.type;
    if (!type) return "?";
    return (
      type.displayName ||
      type.name ||
      type.render?.displayName ||
      type.render?.name ||
      type.type?.displayName ||
      type.type?.name ||
      "anonymous"
    );
  };
  const count = (fiber: Fiber) => {
    const name = nameOf(fiber);
    state.counts[name] = (state.counts[name] ?? 0) + 1;
  };
  const mounted = (fiber: Fiber) => {
    for (let at: Fiber | null = fiber; at; at = at.sibling) {
      if (COMPONENT.has(at.tag)) count(at);
      if (at.child) mounted(at.child);
    }
  };
  const updated = (next: Fiber, prev: Fiber) => {
    if (COMPONENT.has(next.tag) && (next.flags & PERFORMED_WORK) === PERFORMED_WORK) count(next);
    if (next.child === prev.child) return;
    for (let child = next.child; child; child = child.sibling) {
      if (child.alternate) updated(child, child.alternate);
      else {
        if (COMPONENT.has(child.tag)) count(child);
        if (child.child) mounted(child.child);
      }
    }
  };
  const hook = (window as any).__REACT_DEVTOOLS_GLOBAL_HOOK__ ?? {
    renderers: new Map(),
    supportsFiber: true,
    inject(renderer: unknown) {
      const id = hook.renderers.size + 1;
      hook.renderers.set(id, renderer);
      return id;
    },
    onScheduleFiberRoot() {},
    onCommitFiberUnmount() {},
    onPostCommitFiberRoot() {},
    checkDCE() {},
  };
  const previous = hook.onCommitFiberRoot;
  hook.onCommitFiberRoot = (id: number, root: { current: Fiber }, ...rest: unknown[]) => {
    if (state.on) {
      state.commits += 1;
      const current = root.current;
      if (current.alternate) updated(current, current.alternate);
      else if (current.child) mounted(current.child);
    }
    return previous?.call(hook, id, root, ...rest);
  };
  (window as any).__REACT_DEVTOOLS_GLOBAL_HOOK__ = hook;
}

export async function installFiberRenders(page: Page): Promise<void> {
  await page.addInitScript(defineFiberRenders);
}

export async function startFiberRenders(page: Page): Promise<void> {
  await page.evaluate(() => {
    const state = (window as FiberRenderWindow).__fiberRenders!;
    state.counts = {};
    state.commits = 0;
    state.on = true;
  });
}

export async function stopFiberRenders(page: Page): Promise<{ commits: number; counts: Record<string, number> }> {
  return page.evaluate(() => {
    const state = (window as FiberRenderWindow).__fiberRenders!;
    state.on = false;
    return { commits: state.commits, counts: state.counts };
  });
}
