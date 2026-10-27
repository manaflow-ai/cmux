import { createContext, useContext, useRef, useSyncExternalStore } from "react";
import type { AnyRouter } from "@tanstack/react-router";
import type { SectionLoader } from "./lazySections";
import type { ManagedInfo } from "./ops";
import { managedOf, valueOf, type RowError, type SettingsState, type SettingsStore } from "./store";

export type SettingsContextValue = { store: SettingsStore; router: AnyRouter; sections: SectionLoader };

export const SettingsContext = createContext<SettingsContextValue | null>(null);

function useSettingsContext(): SettingsContextValue {
  const value = useContext(SettingsContext);
  if (!value) throw new Error("SettingsContext is missing");
  return value;
}

export function useStore(): SettingsStore {
  return useSettingsContext().store;
}

export function useSettingsRouter(): AnyRouter {
  return useSettingsContext().router;
}

/** The page's section code (lazySections.ts). */
export function useSectionLoader(): SectionLoader {
  return useSettingsContext().sections;
}

/**
 * The page's state: the settings cache (TanStack Query) and the page's UI state, composed by the
 * store. One subscription; the component renders when any part changes. The store decides when to
 * fetch (start, the owner's change events, a section that needs its part), so a mount never reads.
 */
export function useSettingsState(): SettingsState {
  const store = useStore();
  return useSyncExternalStore(store.subscribe, store.getSnapshot, store.getSnapshot);
}

/**
 * The part of the page's state `select` picks; the component renders only when `equal` says that
 * part changed (a write to one key renders that key's row, not every row on the page).
 */
export function useSettingsSelector<T>(
  select: (state: SettingsState) => T,
  equal: (a: T, b: T) => boolean = Object.is,
): T {
  const store = useStore();
  const last = useRef<{ state: SettingsState; select: (state: SettingsState) => T; value: T } | null>(null);
  const read = () => {
    const state = store.getSnapshot();
    const previous = last.current;
    if (previous && previous.state === state && previous.select === select) return previous.value;
    const picked = select(state);
    const value = previous && equal(previous.value, picked) ? previous.value : picked;
    last.current = { state, select, value };
    return value;
  };
  return useSyncExternalStore(store.subscribe, read, read);
}

/** What one setting's row shows. */
export type RowState = {
  value: unknown;
  customized: boolean;
  managed: ManagedInfo | null;
  diagnostics: string[] | undefined;
  error: RowError | undefined;
  connected: boolean;
  readable: boolean;
};

/** One row's state; the row renders only when one of these parts changes. */
export function useRowState(key: string): RowState {
  return useSettingsSelector(
    (state): RowState => ({
      value: valueOf(state, key),
      customized: state.rows.get(key)?.customized ?? false,
      managed: managedOf(state, key),
      diagnostics: state.diagnostics.get(key),
      error: state.errors.get(key),
      connected: state.connected,
      readable: state.readable,
    }),
    shallowEqual,
  );
}

function shallowEqual<T extends object>(a: T, b: T): boolean {
  for (const key in a) if (!Object.is(a[key], b[key])) return false;
  return true;
}
