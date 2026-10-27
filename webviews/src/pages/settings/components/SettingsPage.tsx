import { QueryClientProvider } from "@tanstack/react-query";
import { RouterProvider, type RouterHistory } from "@tanstack/react-router";
import { useState } from "react";
import { UiProvider } from "../../../ui/UiProvider";
import { SettingsContext } from "../context";
import type { SectionLoader } from "../lazySections";
import { createSettingsRouter } from "../router";
import type { SettingsStore } from "../store";
import { SectionRoute } from "./SectionRoute";
import { SettingsApp } from "./SettingsApp";

/** The root: one router (hash history in the app, memory history in tests), the settings query
 * cache, the store and the section code (`sections`, lazySections.ts). The document never scrolls
 * (the content column does), so pop-ups are fixed: they follow their row without growing the
 * document (cx-jh7kq). */
export function SettingsPage({
  store,
  sections,
  history,
}: {
  store: SettingsStore;
  sections: SectionLoader;
  history?: RouterHistory;
}) {
  const [router] = useState(() =>
    createSettingsRouter(
      { layout: SettingsApp, section: SectionRoute, context: { queryClient: store.queryClient, store, sections } },
      history,
    ),
  );
  return (
    <QueryClientProvider client={store.queryClient}>
      <SettingsContext.Provider value={{ store, router, sections }}>
        <UiProvider container={null} overlayPosition="fixed">
          <RouterProvider router={router} />
        </UiProvider>
      </SettingsContext.Provider>
    </QueryClientProvider>
  );
}
