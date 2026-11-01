import { QueryClientProvider } from "@tanstack/react-query";
import { RouterProvider, type RouterHistory } from "@tanstack/react-router";
import { useState } from "react";
import { UiProvider } from "../../../ui/UiProvider";
import type { PopupHost } from "../../../ui/popupHost";
import { SettingsContext } from "../context";
import { createSettingsRouter } from "../router";
import type { SettingsStore } from "../store";
import { SectionRoute } from "./SectionRoute";
import { SettingsApp } from "./SettingsApp";

/** The root: one router (hash history in the app, memory history in tests), the settings query
 * cache and the store. The document never scrolls (the content column does), so pop-ups are
 * fixed: they follow their row without growing the document (cx-jh7kq). */
export function SettingsPage({
  store,
  history,
  popupHost = null,
}: {
  store: SettingsStore;
  history?: RouterHistory;
  popupHost?: PopupHost | null;
}) {
  const [router] = useState(() =>
    createSettingsRouter(
      { layout: SettingsApp, section: SectionRoute, context: { queryClient: store.queryClient, store } },
      history,
    ),
  );
  return (
    <QueryClientProvider client={store.queryClient}>
      <SettingsContext.Provider value={{ store, router }}>
        <UiProvider container={null} overlayPosition="fixed" popupHost={popupHost}>
          <RouterProvider router={router} />
        </UiProvider>
      </SettingsContext.Provider>
    </QueryClientProvider>
  );
}
