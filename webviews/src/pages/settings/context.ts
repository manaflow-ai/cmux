import { createContext, useContext, useSyncExternalStore } from "react";
import type { AnyRouter } from "@tanstack/react-router";
import type { SettingsState, SettingsStore } from "./store";

export type SettingsContextValue = { store: SettingsStore; router: AnyRouter };

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

export function useSettingsState(): SettingsState {
  const store = useStore();
  return useSyncExternalStore(store.subscribe, store.getSnapshot, store.getSnapshot);
}
