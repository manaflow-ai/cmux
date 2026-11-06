import { Outlet, useRouterState } from "@tanstack/react-router";
import { useCallback, useDeferredValue, useEffect, useRef, useState } from "react";
import { useSettingsRouter, useSettingsState, useStore } from "../context";
import { installKeyboard, runPageCommand } from "../keyboard";
import { parseLocation, sectionHref } from "../router";
import { homes, shownSection } from "../categories";
import { rowsByKey } from "../schema";
import { t } from "../strings";
import { filterRows } from "../search";
import { managedOf, valueOf } from "../store";
import { ReadOnlyBanner } from "./ReadOnlyBanner";
import { SearchField } from "./SearchField";
import { SearchResults } from "./SearchResults";
import { SectionList } from "./SectionList";

/**
 * The page (P1): the search field and the categories in the sidebar at the window's left, the
 * category (or the search results, or the changed settings) in a centered column on the right.
 * The root route's component: the category is the matched section route (`<Outlet />`), and the
 * search's text and Changed filter are the route's search (`?q=`, `?changed=1`).
 */
export function SettingsApp() {
  const router = useSettingsRouter();
  const store = useStore();
  const state = useSettingsState();
  const href = useRouterState({ router, select: (routerState) => routerState.location.href });
  const location = parseLocation(href);
  // The field answers each keystroke from its own text; the URL follows (replace, no history
  // entry) and is what the results read. A route change from elsewhere (back, forward, the host,
  // a section link) puts its text in the field.
  const [query, setFieldQuery] = useState(location.query);
  const written = useRef(location.query);
  useEffect(() => {
    if (location.query !== written.current) {
      written.current = location.query;
      setFieldQuery(location.query);
    }
  }, [location.query]);
  const changedOnly = location.changedOnly;
  const replaceSearch = useCallback(
    (next: { query: string; changedOnly: boolean }) => {
      const current = parseLocation(router.state.location.href);
      written.current = next.query;
      router.history.replace(sectionHref(current.section, current.focus, current.workspace, next));
    },
    [router],
  );
  const setQuery = (next: string) => {
    setFieldQuery(next);
    replaceSearch({ query: next, changedOnly });
  };
  const setChangedOnly = (next: boolean) => replaceSearch({ query, changedOnly: next });
  // The field answers each keystroke at once; the results (many rows with editors) render at a
  // lower priority that React can interrupt, so typing never waits on them.
  const shownQuery = useDeferredValue(query);
  const shownChangedOnly = useDeferredValue(changedOnly);
  const searching = shownQuery.trim() !== "" || shownChangedOnly;
  const isChanged = (key: string) => state.rows.get(key)?.customized ?? false;
  const changedCount = [...state.rows.values()].filter((row) => row.customized && homes.has(row.key)).length;

  // A section link or a revealed row ends the search: the field empties with the URL.
  const clearField = useCallback(() => {
    written.current = "";
    setFieldQuery("");
  }, []);
  const go = useCallback(
    (section: string, focus?: string) => {
      clearField();
      router.history.push(sectionHref(section, focus));
    },
    [router, clearField],
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
  // A DEV-only category (Development) is never shown outside DEV builds, however it was reached.
  const section = shownSection(location.section, state.host?.dev_build === true);
  const submit = () => {
    const first = filterRows({
      query,
      changedOnly,
      valueOf: (key) => valueOf(state, key),
      isChanged,
      devBuild: state.host?.dev_build === true,
      scope: "user",
      revision: state.revision,
    })[0]?.rows[0];
    if (first) reveal(first.key);
  };

  return (
    <div className="settings" ref={keyboardRef}>
      <aside className="sidebar">
        <h2 className="sidebar-title">{t("settingsPage.title")}</h2>
        <SearchField
          query={query}
          onQuery={setQuery}
          onSubmit={submit}
          changedOnly={changedOnly}
          changedCount={changedCount}
          onChangedOnly={setChangedOnly}
        />
        <SectionList current={searching ? null : section} onSelect={clearField} />
      </aside>
      <main className="content">
        <div className="column">
          {!state.connected ? (
            <ReadOnlyBanner />
          ) : state.loaded && !state.readable ? (
            <ReadOnlyBanner reason="loadFailed" />
          ) : null}
          {shownChangedOnly && <h1 className="section-title">{t("settingsPage.changedTitle")}</h1>}
          {searching ? <SearchResults query={shownQuery} changedOnly={shownChangedOnly} /> : <Outlet />}
        </div>
      </main>
    </div>
  );
}
