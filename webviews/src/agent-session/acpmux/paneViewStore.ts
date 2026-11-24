// Per-view state for a shared pane document (goal memory-per-chat, paneView.ts): a value the host
// pushes for one chat (its header, tab row, notices, tool cards) is kept per view, so two chats in
// one document never draw each other's. A component reads its own view's value through
// `PaneViewContext`; host code passes the view the event named. The null view is the page itself,
// which is every page today (one chat a page), so a store behaves exactly as its module value did.
import { createContext, useContext, useSyncExternalStore } from "react";

/// The view a component's chat is: null for a page that holds one chat (today's pages).
export const PaneViewContext = createContext<string | null>(null);

/// The view the calling component draws.
export function usePaneView(): string | null {
  return useContext(PaneViewContext);
}

export type ViewStore<T> = {
  /// The view's value; a view nothing set yet reads the initial value.
  get(view?: string | null): T;
  /// Sets the view's value and wakes its readers (only when it changed).
  set(value: T, view?: string | null): void;
  /// Listens to one view's changes.
  subscribe(listener: () => void, view?: string | null): () => void;
  /// Forgets a view that closed, waking its readers with the initial value.
  drop(view: string): void;
  /// Tests: forgets every view's value, waking their readers.
  reset(): void;
  /// The views that hold a value now (the page's own null included), for tests and diagnostics.
  views(): (string | null)[];
  /// React: the calling component's view's value, re-rendered when it changes.
  use(): T;
};

/// A store with one value a view, every view starting at `initial`.
export function viewStore<T>(initial: T): ViewStore<T> {
  const values = new Map<string | null, T>();
  const listeners = new Map<string | null, Set<() => void>>();
  const wake = (view: string | null) => {
    const set = listeners.get(view);
    if (set) for (const listener of [...set]) listener();
  };
  const get = (view: string | null = null): T => (values.has(view) ? (values.get(view) as T) : initial);
  const subscribe = (listener: () => void, view: string | null = null) => {
    let set = listeners.get(view);
    if (!set) {
      set = new Set();
      listeners.set(view, set);
    }
    set.add(listener);
    return () => {
      const current = listeners.get(view);
      if (!current) return;
      current.delete(listener);
      if (current.size === 0) listeners.delete(view);
    };
  };
  return {
    get,
    set(value, view = null) {
      if (Object.is(get(view), value) && values.has(view)) return;
      values.set(view, value);
      wake(view);
    },
    subscribe,
    drop(view) {
      if (!values.delete(view)) return;
      wake(view);
    },
    reset() {
      const views = [...values.keys()];
      values.clear();
      for (const view of views) wake(view);
    },
    views: () => [...values.keys()],
    use() {
      const view = usePaneView();
      return useSyncExternalStore(
        (listener) => subscribe(listener, view),
        () => get(view),
        () => get(view),
      );
    },
  };
}
