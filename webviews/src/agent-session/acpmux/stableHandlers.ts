// A memoized component's event props hold their identity across its parent's renders. The pane builds
// most of the composer's handlers inline (App.tsx), so each pane render, a tool call's among them,
// handed the composer new functions that do the same thing and drew it again for nothing. Each `on*`
// function prop is replaced by one function per prop name that calls the latest one passed, so a
// `memo` around the component sees the same handler until the prop comes or goes.
import { useEffect, useRef } from "react";

type Handler = (...args: unknown[]) => unknown;

/// An event prop: `on` and a capital, as React names them.
const isHandlerKey = (key: string) => /^on[A-Z]/.test(key);

/// `props` with each `on*` function replaced by a stable one that calls the latest `props[key]`.
/// The handlers are for events: they read the props of the parent's last render. `callTime` names
/// other function props that are only called from an event (a send's `holdsSend`), held the same way;
/// a prop read while drawing must not be named there, or the memo would draw with its stale result.
export function useStableHandlers<P extends object>(props: P, callTime: readonly (keyof P & string)[] = []): P {
  const latest = useRef(props);
  latest.current = props;
  const handlers = useRef(new Map<string, Handler>());
  const stable = { ...props } as Record<string, unknown>;
  for (const [key, value] of Object.entries(props)) {
    if (typeof value !== "function" || !(isHandlerKey(key) || (callTime as readonly string[]).includes(key))) continue;
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

/// Counts, under `name.prop:KEY` in acpmuxPerf's renders, each prop of a memoized component whose
/// identity changed since the last render of its parent: the props that draw it again. Inert until a
/// debug call turns measurement on (`cmuxAcpmuxDebug.renders()`), so a test can name what churned.
export function usePropChurn(name: string, props: object, enabled: boolean, count: (key: string) => void): void {
  const last = useRef<Record<string, unknown> | undefined>(undefined);
  // Compared after each render, in an effect with no dependencies: a ref written while rendering makes
  // the React Compiler skip the hook.
  useEffect(() => {
    const now = props as Record<string, unknown>;
    const before = last.current;
    last.current = now;
    if (enabled && before) countChurn(name, before, now, count);
  });
}

function countChurn(
  name: string,
  before: Record<string, unknown>,
  now: Record<string, unknown>,
  count: (key: string) => void,
): void {
  for (const key of new Set([...Object.keys(before), ...Object.keys(now)])) {
    const was = before[key];
    const is = now[key];
    if (Object.is(was, is)) continue;
    count(`${name}.prop:${key}`);
    // An object prop names the members that changed too (`snapshot.summary`), one level down.
    if (was && is && typeof was === "object" && typeof is === "object" && !Array.isArray(was))
      for (const member of new Set([...Object.keys(was), ...Object.keys(is)]))
        if (!Object.is((was as Record<string, unknown>)[member], (is as Record<string, unknown>)[member]))
          count(`${name}.prop:${key}.${member}`);
  }
}
