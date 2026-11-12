"use client";

import { useCallback, useRef, useState } from "react";

export type AsyncActionState = {
  readonly pending: boolean;
  readonly error: string | null;
  /** Clears a previously reported error, for example when input changes. */
  readonly clearError: () => void;
  /** Reports an error without running an action (validation messages). */
  readonly setError: (message: string | null) => void;
};

/**
 * Runs an async event handler with a pending flag and an inline error
 * message. The returned `run` resolves to `true` on success. A thrown error
 * shows `fallbackError` (callers pass a translated string), or the message
 * returned by `describeError` when it knows the failure.
 *
 * This replaces `runAsynchronouslyWithAlert` from the Hexclave components,
 * which reported failures with `window.alert`.
 */
export function useAsyncAction(
  fallbackError: string,
  describeError?: (error: unknown) => string | null,
): [run: (action: () => Promise<void>) => Promise<boolean>, state: AsyncActionState] {
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const inFlight = useRef(false);

  const run = useCallback(
    async (action: () => Promise<void>) => {
      if (inFlight.current) return false;
      inFlight.current = true;
      setPending(true);
      setError(null);
      try {
        await action();
        return true;
      } catch (caught) {
        setError(describeError?.(caught) ?? fallbackError);
        return false;
      } finally {
        inFlight.current = false;
        setPending(false);
      }
    },
    [describeError, fallbackError],
  );

  const clearError = useCallback(() => setError(null), []);
  return [run, { pending, error, clearError, setError }];
}
