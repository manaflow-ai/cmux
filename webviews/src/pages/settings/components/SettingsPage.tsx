import { QueryClientProvider } from "@tanstack/react-query";
import { RouterProvider, type RouterHistory } from "@tanstack/react-router";
import { useState } from "react";
import { SettingsContext } from "../context";
import { createSettingsRouter } from "../router";
import type { SettingsStore } from "../store";
import { SettingsApp } from "./SettingsApp";

/** The root: one router (hash history in the app, memory history in tests), the settings query
 * cache and the store. */
export function SettingsPage({ store, history }: { store: SettingsStore; history?: RouterHistory }) {
  const [router] = useState(() => createSettingsRouter(SettingsApp, history));
  return (
    <QueryClientProvider client={store.queryClient}>
      <SettingsContext.Provider value={{ store, router }}>
        <RouterProvider router={router} />
      </SettingsContext.Provider>
    </QueryClientProvider>
  );
}
