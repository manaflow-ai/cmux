// A memoized component's event props hold their identity across its parent's renders. The pane builds
// most of the composer's handlers inline (App.tsx), so each pane render, a tool call's among them,
// handed the composer new functions that do the same thing and drew it again for nothing. Each `on*`
// function prop is replaced by one function per prop name that calls the latest one passed, so a
// `memo` around the component sees the same handler until the prop comes or goes.
import { useCallback, useInsertionEffect, useRef } from "react";

type Handler = (...args: unknown[]) => unknown;

/// An event prop: `on` and a capital, as React names them.
const isHandlerKey = (key: string) => /^on[A-Z]/.test(key);

/// `props` with each `on*` function replaced by a stable one that calls the latest `props[key]`.
/// The handlers are for events: they read the props of the parent's last render.
export function useStableHandlers<P extends object>(props: P): P {
  const latest = useRef(props);
  latest.current = props;
  const handlers = useRef(new Map<string, Handler>());
  const stable = { ...props } as Record<string, unknown>;
  for (const [key, value] of Object.entries(props)) {
    if (typeof value !== "function" || !isHandlerKey(key)) continue;
    let handler = handlers.current.get(key);
    if (!handler) {
      handler = (...args: unknown[]) =>
        ((latest.current as Record<string, unknown>)[key] as Handler | undefined)?.(...args);
      handlers.current.set(key, handler);
    }
    stable[key] = handler;
  }
  return stable as P;
}

/// One function, the same on every render, that calls the latest `handler`: for an event prop a
/// compiled component builds from values a key changes (the draft, its caret), so the element it is
/// passed to is the same on the next key. `handler` is written as the render commits, never during
/// it (a write during render keeps the component out of the React Compiler); call the result from
/// events and effects only, never while rendering.
export function useLatestHandler<A extends unknown[], R>(handler: (...args: A) => R): (...args: A) => R {
  const latest = useRef(handler);
  useInsertionEffect(() => {
    latest.current = handler;
  });
  return useCallback((...args: A) => latest.current(...args), []);
}
