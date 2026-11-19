import { useCallback, useInsertionEffect, useRef } from "react";

/// A function with one identity for the component's life that calls the latest `callback`, for a
/// list to hand every row (a memo row then draws again only when its own data changes). Call it
/// from events and effects, not while drawing: it reads the callback of the last commit.
export function useStableCallback<A extends unknown[], R>(callback: (...args: A) => R): (...args: A) => R {
  const latest = useRef(callback);
  useInsertionEffect(() => {
    latest.current = callback;
  });
  return useCallback((...args: A) => latest.current(...args), []);
}
