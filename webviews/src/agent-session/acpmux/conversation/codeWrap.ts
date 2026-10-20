import { useState, useSyncExternalStore } from "react";

/// One wrap choice for the pane, kept even when code cards remount (Lucas 2026-10-18).
const KEY = "cmux.acpmux.codeWrap";
let shared: boolean | undefined;
const listeners = new Set<() => void>();
const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => void listeners.delete(listener);
};

function current(): boolean {
  if (shared === undefined) {
    try {
      shared = localStorage.getItem(KEY) === "true";
    } catch {
      shared = false;
    }
  }
  return shared;
}

function toggle(): void {
  shared = !current();
  try {
    localStorage.setItem(KEY, String(shared));
  } catch {
    // Blocked storage keeps the choice for this pane only.
  }
  for (const listener of listeners) listener();
}

export function useCodeWrap(enabled: boolean): [boolean, () => void] {
  const [local, setLocal] = useState(false);
  const wrap = useSyncExternalStore(
    subscribe,
    () => enabled && current(),
    () => false,
  );
  return enabled ? [wrap, toggle] : [local, () => setLocal((value) => !value)];
}
