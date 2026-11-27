import { QueryClientProvider } from "@tanstack/react-query";
import { RouterProvider, type RouterHistory } from "@tanstack/react-router";
import { useCallback, useLayoutEffect, useRef, useState, useSyncExternalStore } from "react";
import { UiProvider } from "../../../ui/UiProvider";
import { SettingsContext } from "../context";
import { createSettingsRouter } from "../router";
import type { SettingsStore } from "../store";
import { locale, subscribeLocale } from "../strings";
import { drawNextCategoryWhole } from "./GroupList";
import { SectionRoute } from "./SectionRoute";
import { SettingsApp } from "./SettingsApp";

/** The page's scrolling columns, whose offsets a language change keeps. */
const SCROLLERS = [".settings .content", ".settings .sidebar-scroll-viewport"];

/** The root: one router (hash history in the app, memory history in tests), the settings query
 * cache and the store. The document never scrolls (the content column does), so pop-ups are
 * fixed: they follow their row without growing the document (cx-jh7kq).
 *
 * The page follows the app's language live (Settings > General > Language): the strings are
 * module-level `t()` reads the React Compiler would keep memoized, so a language change draws the
 * routes again under a new key. The route, the search text (the URL's), the store and its query
 * cache stay; each column keeps its scroll offset and the category draws whole, so nothing jumps. */
export function SettingsPage({ store, history }: { store: SettingsStore; history?: RouterHistory }) {
  const [router] = useState(() =>
    createSettingsRouter(
      { layout: SettingsApp, section: SectionRoute, context: { queryClient: store.queryClient, store } },
      history,
    ),
  );
  const offsets = useRef<number[] | null>(null);
  const subscribe = useCallback((changed: () => void) => {
    return subscribeLocale(() => {
      const doc = globalThis.document;
      offsets.current = SCROLLERS.map((selector) => doc?.querySelector(selector)?.scrollTop ?? 0);
      drawNextCategoryWhole();
      changed();
    });
  }, []);
  const language = useSyncExternalStore(subscribe, locale, locale);
  useLayoutEffect(() => {
    const kept = offsets.current;
    if (!kept) return;
    offsets.current = null;
    SCROLLERS.forEach((selector, index) => {
      const scroller = globalThis.document?.querySelector(selector);
      if (scroller) scroller.scrollTop = kept[index] ?? 0;
    });
  }, [language]);
  return (
    <QueryClientProvider client={store.queryClient}>
      <SettingsContext.Provider value={{ store, router }}>
        <UiProvider container={null} overlayPosition="fixed">
          <RouterProvider key={language} router={router} />
        </UiProvider>
      </SettingsContext.Provider>
    </QueryClientProvider>
  );
}
