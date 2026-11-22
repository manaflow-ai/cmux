import { useRouterState } from "@tanstack/react-router";
import { useCallback, useDeferredValue, useState } from "react";
import { useSettingsRouter, useSettingsState, useStore } from "../context";
import { installKeyboard, runPageCommand } from "../keyboard";
import { parseLocation, sectionHref } from "../router";
import { homes } from "../categories";
import { rowsByKey } from "../schema";
import { t } from "../strings";
import { filterRows } from "../search";
import { managedOf, valueOf } from "../store";
import { ReadOnlyBanner } from "./ReadOnlyBanner";
import { SearchField } from "./SearchField";
import { SearchResults } from "./SearchResults";
import { SectionList } from "./SectionList";
import { SectionView } from "./SectionView";

/**
 * The page (P1): the search field and the categories in the sidebar at the window's left, the
 * category (or the search results, or the changed settings) in a centered column on the right.
 */
export function SettingsApp() {
  const router = useSettingsRouter();
  const store = useStore();
  const state = useSettingsState();
  const href = useRouterState({ router, select: (routerState) => routerState.location.href });
  const location = parseLocation(href);
  const [query, setQuery] = useState("");
  const [changedOnly, setChangedOnly] = useState(false);
  // The field answers each keystroke at once; the results (many rows with editors) render at a
  // lower priority that React can interrupt, so typing never waits on them.
  const shownQuery = useDeferredValue(query);
  const shownChangedOnly = useDeferredValue(changedOnly);
  const searching = shownQuery.trim() !== "" || shownChangedOnly;
  const isChanged = (key: string) => state.rows.get(key)?.customized ?? false;
  const changedCount = [...state.rows.values()].filter((row) => row.customized && homes.has(row.key)).length;

  const go = useCallback(
    (section: string, focus?: string) => {
      setQuery("");
      setChangedOnly(false);
      router.history.push(sectionHref(section, focus));
    },
    [router],
  );
  const reveal = useCallback(
    (key: string) => {
      const row = rowsByKey.get(key);
      if (row) go(homes.get(key)?.category ?? row.section, key);
    },
    [go],
  );
  // Stable across renders, so the document listeners are installed once per mount.
  const keyboardRef = useCallback(
    (root: HTMLDivElement | null) => {
      if (!root) return;
      const actions = {
        back: () => router.history.back(),
        forward: () => router.history.forward(),
        reveal,
        reset: (key: string) => {
          const current = store.getSnapshot();
          if (current.rows.get(key)?.customized && !managedOf(current, key)) void store.reset(key);
        },
      };
      const removeKeys = installKeyboard(root, actions);
      const removeCommands = store.onCommand((command) => runPageCommand(root.ownerDocument, command, actions));
      return () => {
        removeKeys();
        removeCommands();
      };
    },
    [router, store, reveal],
  );
  const submit = () => {
    const first = filterRows({ query, changedOnly, valueOf: (key) => valueOf(state, key), isChanged })[0]?.rows[0];
    if (first) reveal(first.key);
  };

  return (
    <div className="settings" ref={keyboardRef}>
      <aside className="sidebar">
        <SearchField
          query={query}
          onQuery={setQuery}
          onSubmit={submit}
          changedOnly={changedOnly}
          changedCount={changedCount}
          onChangedOnly={setChangedOnly}
        />
        <SectionList current={searching ? null : location.section} onSelect={(section) => go(section)} />
      </aside>
      <main className="content">
        <div className="column">
          {!state.connected ? (
            <ReadOnlyBanner />
          ) : state.loaded && !state.readable ? (
            <ReadOnlyBanner reason="loadFailed" />
          ) : null}
          {shownChangedOnly && <h1 className="section-title">{t("settingsPage.changedTitle")}</h1>}
          {searching ? (
            <SearchResults query={shownQuery} changedOnly={shownChangedOnly} />
          ) : (
            <SectionView key={location.section} section={location.section} focus={location.focus} />
          )}
        </div>
      </main>
    </div>
  );
}
