import { useRouterState } from "@tanstack/react-router";
import { useState } from "react";
import { useSettingsRouter, useSettingsState, useStore } from "../context";
import { installKeyboard } from "../keyboard";
import { parseLocation, sectionHref } from "../router";
import { rowsByKey } from "../schema";
import { searchRows } from "../search";
import { managedOf, valueOf } from "../store";
import { ReadOnlyBanner } from "./ReadOnlyBanner";
import { SearchField } from "./SearchField";
import { SearchResults } from "./SearchResults";
import { SectionList } from "./SectionList";
import { SectionView } from "./SectionView";

/** The page: search and sections on the left, the section or the search results on the right. */
export function SettingsApp() {
  const router = useSettingsRouter();
  const store = useStore();
  const state = useSettingsState();
  const href = useRouterState({ router, select: (routerState) => routerState.location.href });
  const location = parseLocation(href);
  const [query, setQuery] = useState("");
  const searching = query.trim() !== "";

  const go = (section: string, focus?: string) => {
    setQuery("");
    router.history.push(sectionHref(section, focus));
  };
  const reveal = (key: string) => {
    const row = rowsByKey.get(key);
    if (row) go(row.section, key);
  };
  const keyboardRef = (root: HTMLDivElement | null) => {
    if (!root) return;
    return installKeyboard(root, {
      back: () => router.history.back(),
      forward: () => router.history.forward(),
      reveal,
      reset: (key) => {
        const current = store.getSnapshot();
        if (current.rows.get(key)?.customized && !managedOf(current, key)) void store.reset(key);
      },
    });
  };
  const submit = () => {
    const first = searchRows(query, (key) => valueOf(state, key))[0]?.rows[0];
    if (first) reveal(first.key);
  };

  return (
    <div className="settings" ref={keyboardRef}>
      <aside className="sidebar">
        <SearchField query={query} onQuery={setQuery} onSubmit={submit} />
        <SectionList current={searching ? null : location.section} onSelect={(section) => go(section)} />
      </aside>
      <main className="content">
        {!state.connected && <ReadOnlyBanner />}
        {searching ? (
          <SearchResults query={query} />
        ) : (
          <SectionView section={location.section} focus={location.focus} />
        )}
      </main>
    </div>
  );
}
