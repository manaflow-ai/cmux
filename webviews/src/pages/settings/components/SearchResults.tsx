import { lazy, Suspense, useMemo, useState, memo } from "react";
import { shownCategories, sidebarSections } from "../categories";
import { useStore, shallowEqual, useSettingsSelector, useSettingsRouter } from "../context";
import type { SettingsState } from "../store";
import { Icon } from "../icons";
import { sectionHref } from "../router";
import { filterRows, filterPages, filterPlaces, joinConsentPlaces } from "../search";
import { rowsByKey } from "../schema";
import { t, text } from "../strings";
import { CHIEF_PET_ROWS } from "../cardRows";
import { AskCmuxRow } from "./AskCmuxRow";
import { GroupList } from "./GroupList";

/** Each category's page title (the sidebar section that holds it), for a result's crumb. */
const pageTitles = new Map(
  sidebarSections.flatMap((section) =>
    section.title ? section.categories.map((id) => [id, section.title!] as const) : [],
  ),
);

const searchInputs = (state: SettingsState) => ({
  rows: state.rows,
  revision: state.revision,
  devBuild: state.host?.dev_build === true,
  // Settings > Devices' join consent state: the page-only places search matches beside the rows.
  join: state.host?.devices_join ?? null,
});

// The Chief Pet card (and its characters' art) loads when a search first shows its rows, not with the page.
const ChiefPetCard = lazy(() => import("./ChiefPetCard").then(({ ChiefPetCard }) => ({ default: ChiefPetCard })));
// Settings > Devices' join consent switches, likewise, when a search first matches one.
const JoinGroup = lazy(() => import("./DevicesCard").then(({ JoinGroup }) => ({ default: JoinGroup })));

/**
 * Matching rows from every category, editable in place, grouped by category under a crumb, its
 * page then the category ("AI › Agents"; a page's own category is just its name), so a result says
 * where it lives among the six pages (findings G6, the search-first layout's results). Every
 * row stays mounted while the filter is on: a row that stops matching collapses (height and
 * opacity) and one that starts matching opens, so the list never jumps between keystrokes. Page-only
 * places match beside the rows (search.ts `PagePlace`): Settings > Devices' join consent switches show,
 * live, under Devices.
 */
// A memo component: the page draws again on any change to its state (the host's lists among them),
// and the results take only the query.
export const SearchResults = memo(function SearchResults({ query }: { query: string }) {
  // Only what the filter reads: the values (a search finds a row by its value), the owner's
  // revision, whether the host is a DEV build and Devices' join consent state. The host's lists, connectivity and every other
  // part of the page's state change without filtering again or drawing the results.
  const { rows, revision, devBuild, join } = useSettingsSelector(searchInputs, shallowEqual);
  const store = useStore();
  const categories = useMemo(() => shownCategories(devBuild), [devBuild]);
  const matches = useMemo(
    () =>
      filterRows({
        query,
        // valueOf (store.ts) as it reads `state.rows`: the owner's value, else the schema's default.
        valueOf: (key) => {
          const row = rows.get(key);
          return row ? row.value : rowsByKey.get(key)?.default;
        },
        devBuild,
        scope: "user",
        revision,
      }),
    [devBuild, query, rows, revision],
  );
  const shown = useMemo(() => new Set(matches.flatMap((match) => match.rows.map((row) => row.key))), [matches]);
  const places = useMemo(() => filterPlaces(query, joinConsentPlaces(join)), [join, query]);
  const shownPlaces = useMemo(() => new Set(places.map((place) => place.key)), [places]);
  // Pages the words name (their title, or the words of cards that draw no schema rows, such as
  // Devices' Screen sharing and Control): a link to each, above the rows.
  const pages = useMemo(() => filterPages({ query, devBuild }), [devBuild, query]);
  const router = useSettingsRouter();
  const empty = shown.size === 0 && places.length === 0 && pages.length === 0;
  const crumb = (category: { id: string; title: Parameters<typeof text>[0] }) => {
    const page = pageTitles.get(category.id);
    const name = page ? text(page) : null;
    return name && name !== text(category.title) ? name : null;
  };
  // Only rows that matched at some point in this search mount their editors (a row that stops
  // matching keeps its content to collapse smoothly); the rest stay empty, collapsed slots, so
  // opening search costs the matches, not every setting.
  const [mounted, setMounted] = useState<ReadonlySet<string>>(shown);
  if ([...shown].some((key) => !mounted.has(key))) setMounted(new Set([...mounted, ...shown]));
  return (
    <div className="search-results" data-search-results="">
      <div className="empty collapse" data-open={empty ? "" : undefined}>
        <div className="collapse-body">
          <p>{t("settingsPage.noResults")}</p>
          {empty && query.trim() ? <AskCmuxRow words={query} onAsk={() => void store.askCmux(query)} /> : null}
        </div>
      </div>
      {pages.length > 0 && (
        <div className="search-pages" data-search-pages="">
          {pages.map((page) => {
            const section = sidebarSections.find((run) => run.categories.includes(page.id))?.title;
            return (
              <button
                type="button"
                className="ask-cmux search-page"
                key={page.id}
                data-page-hit={page.id}
                onClick={() => router.history.push(sectionHref(page.id))}
              >
                <Icon name="arrow.turn.down.right" />
                <span className="ask-cmux-text">
                  <span className="ask-cmux-title">{text(page.title)}</span>
                  {section ? <span className="ask-cmux-words">{text(section)}</span> : null}
                </span>
              </button>
            );
          })}
        </div>
      )}
      {categories.map((category) => {
        const joinShown = join !== null && places.some((place) => place.category === category.id);
        const open = joinShown || category.groups.some((group) => group.rows.some((row) => shown.has(row.key)));
        const pet = category.id === "chief";
        const petRows = pet
          ? new Set(
              category.groups
                .flatMap((group) => group.rows)
                .filter((row) => shown.has(row.key) && CHIEF_PET_ROWS.has(row.key))
                .map((row) => row.key),
            )
          : null;
        const groups = pet
          ? category.groups
              .map((group) => ({ ...group, rows: group.rows.filter((row) => !CHIEF_PET_ROWS.has(row.key)) }))
              .filter((group) => group.rows.length > 0)
          : category.groups;
        return (
          <section
            className="result-section collapse"
            key={category.id}
            data-section={category.id}
            data-open={open ? "" : undefined}
            inert={!open}
            aria-hidden={open ? undefined : true}
          >
            <div className="collapse-body">
              <h2 className="result-section-title">
                {crumb(category) && (
                  <>
                    <span className="result-section-page">{crumb(category)}</span>
                    <span className="result-section-crumb" aria-hidden="true">
                      {" › "}
                    </span>
                  </>
                )}
                {text(category.title)}
              </h2>
              {petRows && petRows.size > 0 && (
                <Suspense fallback={null}>
                  <ChiefPetCard query={query} visibleRows={petRows} />
                </Suspense>
              )}
              {joinShown && join && (
                <Suspense fallback={null}>
                  <JoinGroup join={join} only={shownPlaces} query={query} />
                </Suspense>
              )}
              <GroupList groups={groups} query={query} shown={shown} mounted={mounted} />
            </div>
          </section>
        );
      })}
    </div>
  );
});
