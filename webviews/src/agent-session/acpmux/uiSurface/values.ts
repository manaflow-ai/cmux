// The field values a surface card holds while the person edits (DESIGN "Binding stays in the host":
// edits stay on the page until a confirmed action's `sends`). One store per card, keyed by `bind`;
// a field subscribes to its own key, so typing in one field re-renders that field only.
import { createContext, useCallback, useContext, useSyncExternalStore } from "react";
import type { UiFieldValue, UiSurfaceValues } from "./model";

export class SurfaceValues {
  private values: UiSurfaceValues;
  /// Keys the person changed: a later surface update keeps their value, not Rust's.
  private readonly edited = new Set<string>();
  private readonly listeners = new Map<string, Set<() => void>>();
  private readonly changeListeners = new Set<(key: string) => void>();

  constructor(initial: UiSurfaceValues) {
    this.values = { ...initial };
  }

  get(key: string): UiFieldValue | undefined {
    return this.values[key];
  }

  /// Every value, as `uiSurfaceAction` sends them.
  snapshot(): UiSurfaceValues {
    return { ...this.values };
  }

  set(key: string, value: UiFieldValue) {
    if (this.values[key] === value) return;
    this.values = { ...this.values, [key]: value };
    this.edited.add(key);
    for (const listener of this.listeners.get(key) ?? []) listener();
    for (const listener of this.changeListeners) listener(key);
  }

  /// Rust's latest values for keys the person has not edited.
  adopt(next: UiSurfaceValues) {
    for (const [key, value] of Object.entries(next)) {
      if (this.edited.has(key) || this.values[key] === value) continue;
      this.values = { ...this.values, [key]: value };
      for (const listener of this.listeners.get(key) ?? []) listener();
    }
  }

  subscribe(key: string, listener: () => void): () => void {
    let set = this.listeners.get(key);
    if (!set) this.listeners.set(key, (set = new Set()));
    set.add(listener);
    return () => void set.delete(listener);
  }

  /// Any edit by the person (a changed value drops a pending request).
  onEdit(listener: (key: string) => void): () => void {
    this.changeListeners.add(listener);
    return () => void this.changeListeners.delete(listener);
  }
}

export const SurfaceValuesContext = createContext<SurfaceValues | null>(null);

/// One key's value and its setter.
export function useSurfaceValue(key: string): [UiFieldValue | undefined, (value: UiFieldValue) => void] {
  const store = useContext(SurfaceValuesContext);
  const subscribe = useCallback((listener: () => void) => store?.subscribe(key, listener) ?? (() => {}), [store, key]);
  const value = useSyncExternalStore(subscribe, () => store?.get(key));
  const set = useCallback((next: UiFieldValue) => store?.set(key, next), [store, key]);
  return [value, set];
}
