// A loading state in the pane always ends (ui-state-fixes, "Rule for every surface"): a read that
// never answers turns into a failure with Try Again after LOAD_DEADLINE_MS, never "loading" forever.
// One hook for every such wait in the pane: the `/` menu's "Loading commands…" (Composer,
// NewTabScreen) and an existing chat's "Loading conversation…" (chatLoadState.ts).
import { useCallback, useEffect, useState } from "react";

/// How long the pane says something is loading before it says it could not load it (with Try Again).
/// The same 10 s as Settings' part reads and the Mobile Pairing page.
export const LOAD_DEADLINE_MS = 10_000;

/// Runs `fire` once after `ms`; the returned function cancels it. Tests pass their own.
export type Schedule = (fire: () => void, ms: number) => () => void;

export const scheduleTimeout: Schedule = (fire, ms) => {
  const timer = setTimeout(fire, ms);
  return () => clearTimeout(timer);
};

export type LoadDeadlineOptions = { ms?: number; schedule?: Schedule };

/// A wait that ends: `timedOut` turns true once `loading` has held for `ms` (default
/// LOAD_DEADLINE_MS) under the same `key` (what is loading: a chat). It is false at once when the
/// load ends; a new stretch of loading, another key, or `restart` (Try Again) starts a fresh
/// deadline. One timer per stretch, cleared when it ends or the component goes: nothing runs idle.
export function useLoadDeadline(
  loading: boolean,
  key?: string,
  { ms = LOAD_DEADLINE_MS, schedule = scheduleTimeout }: LoadDeadlineOptions = {},
): { timedOut: boolean; restart(): void } {
  // Each stretch of loading counts once, adjusted while rendering, so a load that ends and starts
  // again under the same key never inherits the last stretch's timeout.
  const [stretch, setStretch] = useState({ loading, count: 0 });
  if (stretch.loading !== loading) setStretch({ loading, count: stretch.count + (loading ? 1 : 0) });
  const [attempt, setAttempt] = useState(0);
  const [firedFor, setFiredFor] = useState<string>();
  const token = `${key ?? ""}\u0000${stretch.count}\u0000${attempt}`;
  useEffect(() => {
    if (!loading) return;
    return schedule(() => setFiredFor(token), ms);
  }, [loading, token, ms, schedule]);
  const restart = useCallback(() => setAttempt((count) => count + 1), []);
  return { timedOut: loading && firedFor === token, restart };
}

/// The `/` menu's command list as it shows (M7): "Loading commands…" (`pending`) ends after
/// LOAD_DEADLINE_MS in "Couldn't load commands." with Try Again (`failed`), as a read that failed
/// does. `retry` (Try Again) starts a fresh deadline and asks `onRetry` to read the list again; it
/// is undefined while the list does not stand failed. `key` is the chat whose list it is.
export function useCommandsDeadline(
  list: { commandsPending?: true; commandsFailed?: true },
  key: string | undefined,
  onRetry: (() => void) | undefined,
  options?: LoadDeadlineOptions,
): { pending: boolean; failed: boolean; retry: (() => void) | undefined } {
  const pending = list.commandsPending === true && list.commandsFailed !== true;
  const { timedOut, restart } = useLoadDeadline(pending, key, options);
  const failed = list.commandsFailed === true || timedOut;
  return {
    pending: pending && !timedOut,
    failed,
    retry:
      failed && (onRetry || timedOut)
        ? () => {
            restart();
            onRetry?.();
          }
        : undefined,
  };
}
