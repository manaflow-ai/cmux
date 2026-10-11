import { createContext, useContext, useSyncExternalStore } from "react";
import { useQuery } from "@tanstack/react-query";
import type { AnyRouter } from "@tanstack/react-router";
import {
  settingsKeys,
  type AccountsData,
  type HarnessesData,
  type HostData,
  type ScopeData,
  type ThemeColorsData,
} from "./queries";
import { composeState, type SettingsState, type SettingsStore } from "./store";

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

// The cache's observers only read: the store decides when to fetch (start, the owner's change
// events, a section that needs its part), so a mount never starts a second read.
const reader = { enabled: false } as const;

/** The page's state: the settings cache (TanStack Query) and the page's UI state, composed. */
export function useSettingsState(): SettingsState {
  const store = useStore();
  const ui = useSyncExternalStore(store.subscribe, store.getUi, store.getUi);
  const scope = useQuery<ScopeData>({ queryKey: settingsKeys.scope("user"), ...reader });
  const host = useQuery<HostData>({ queryKey: settingsKeys.host, ...reader });
  const accounts = useQuery<AccountsData>({ queryKey: settingsKeys.accounts, ...reader });
  const harnesses = useQuery<HarnessesData>({ queryKey: settingsKeys.harnesses, ...reader });
  const themeColors = useQuery<ThemeColorsData>({ queryKey: settingsKeys.themeColors, ...reader });
  return composeState(ui, {
    scope: scope.data,
    scopeSettled: scope.status !== "pending",
    host: host.data,
    accounts: accounts.data,
    harnesses: harnesses.data,
    themeColors: themeColors.data,
  });
}
