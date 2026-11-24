import { Outlet, useRouterState } from "@tanstack/react-router";
import { useCallback, useDeferredValue, useEffect, useRef, useState } from "react";
import { useSettingsRouter, useSettingsState, useStore } from "../context";
import { installKeyboard, runPageCommand } from "../keyboard";
import { CLOUD_MODELS_FOCUS, parseLocation, sectionHref } from "../router";
import { homes, shownSection } from "../categories";
import { rowsByKey } from "../schema";
import { filterRows, modelSettingsMatches } from "../search";
import { managedOf, valueOf } from "../store";
import { ReadOnlyNotice } from "./ReadOnlyBanner";
import { SearchField } from "./SearchField";
import { TryOnSlot } from "./TryOnBar";
import { DoctorNoticeSlot } from "./CustomizeDoctorCard";
import { SearchResults } from "./SearchResults";
import { SectionList } from "./SectionList";
import { ScrollArea } from "../../../ui/ScrollArea";
import { whenPageShown } from "../../shared/paintGate";

/**
 * The page (P1): the search field and the categories in the sidebar at the window's left, the
 * category (or the search results) in a centered column on the right. The root route's
 * component: the category is the matched section route (`<Outlet />`), and the search's text is
 * the route's search (`?q=`).
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
  const replaceSearch = useCallback(
    (next: { query: string }) => {
      const current = parseLocation(router.state.location.href);
      written.current = next.query;
      router.history.replace(sectionHref(current.section, current.focus, current.workspace, next));
    },
    [router],
  );
  const setQuery = (next: string) => {
    setFieldQuery(next);
    replaceSearch({ query: next });
  };
  // The field answers each keystroke at once; the results (many rows with editors) render at a
  // lower priority that React can interrupt, so typing never waits on them.
  const shownQuery = useDeferredValue(query);
  const searching = shownQuery.trim() !== "";

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
  // The category the page opens on draws still: no entrance on the open, whose first shown frame is
  // the settled page (Leo, 2026-10-20: "the settings flicker is bad when you load it";
  // settings-open-frames). The open is every category shown before the page is (a pooled page's
  // claim may route it first, paintGate.ts); a category picked after that fades in (layout.css
  // `settings-enter`).
  const [pageShown, setPageShown] = useState(false);
  useEffect(() => whenPageShown(() => setPageShown(true)), []);
  const [openedOn, setOpenedOn] = useState(section);
  if (!pageShown && section !== openedOn) setOpenedOn(section);
  const [switched, setSwitched] = useState(false);
  if (pageShown && !switched && section !== openedOn) setSwitched(true);
  // A click on the category already shown takes its page back to the top (Lucas 2026-11-11), as a
  // second click on a native sidebar's current item or a browser's tab does.
  const content = useRef<HTMLElement>(null);
  const select = (category: string) => {
    if (category === section && !searching) content.current?.scrollTo?.({ top: 0 });
    clearField();
  };
  const submit = () => {
    const first = filterRows({
      query,
      valueOf: (key) => valueOf(state, key),
      devBuild: state.host?.dev_build === true,
      scope: "user",
      revision: state.revision,
    })[0]?.rows[0];
    const matches = modelSettingsMatches(query);
    if (matches.models) go("models");
    else if (matches.cloud) go("cloud", CLOUD_MODELS_FOCUS);
    else if (first) reveal(first.key);
    // Nothing matches: Return asks cmux for it, as the row under "No settings match." does.
    else if (query.trim()) void store.askCmux(query);
  };

  return (
    <div
      className="settings"
      ref={keyboardRef}
      data-section-switched={switched ? "" : undefined}
      data-page-shown={pageShown ? "" : undefined}
    >
      <aside className="sidebar">
        <SearchField query={query} onQuery={setQuery} onSubmit={submit} />
        {/* The categories scroll under the search in the app's own thin scrollbar, the one the New Tab
            page's folder menu draws (Lucas 2026-11-11), never WebKit's. No title above the search and
            no notice under the list (Lawrence 2026-11-23: "remove settings header ... remove this
            thing"): the window already says Settings, and Personalization's card holds the doctor's
            findings. */}
        <ScrollArea fade className="sidebar-scroll" viewportClassName="sidebar-scroll-viewport">
          <SectionList current={searching ? null : section} onSelect={select} />
        </ScrollArea>
      </aside>
      <main className="content" ref={content}>
        <div className="column">
          <ReadOnlyNotice connected={state.connected} loaded={state.loaded} readable={state.readable} />
          <TryOnSlot />
          <DoctorNoticeSlot place="banner" />
          {searching ? <SearchResults query={shownQuery} /> : <Outlet />}
        </div>
      </main>
    </div>
  );
}
