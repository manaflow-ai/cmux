import { lazy, Suspense, useMemo, useState } from "react";
import { shownCategories, sidebarSections } from "../categories";
import { useSettingsRouter, useSettingsState, useStore } from "../context";
import { Icon } from "../icons";
import { sectionHref } from "../router";
import { filterPages, filterPlaces, filterRows, joinConsentPlaces } from "../search";
import { valueOf } from "../store";
import { t, text } from "../strings";
import { CHIEF_PET_ROWS } from "../cardRows";
import { AskCmuxRow } from "./AskCmuxRow";
import { GroupList } from "./GroupList";

// The Chief Pet card (and its characters' art) loads when a search first shows its rows, not with the page.
const ChiefPetCard = lazy(() => import("./ChiefPetCard").then(({ ChiefPetCard }) => ({ default: ChiefPetCard })));
// Settings > Devices' join consent switches, likewise, when a search first matches one.
const JoinGroup = lazy(() => import("./DevicesCard").then(({ JoinGroup }) => ({ default: JoinGroup })));

/**
 * Matching rows from every category, editable in place, grouped by category. Every
 * row stays mounted while the filter is on: a row that stops matching collapses (height and
 * opacity) and one that starts matching opens, so the list never jumps between keystrokes. Page-only
 * places match beside the rows (search.ts `PagePlace`): Settings > Devices' join consent switches show,
 * live, under Devices.
 */
export function SearchResults({ query }: { query: string }) {
  const state = useSettingsState();
  const store = useStore();
  const devBuild = state.host?.dev_build === true;
  const categories = useMemo(() => shownCategories(devBuild), [devBuild]);
  const matches = useMemo(
    () =>
      filterRows({
        query,
        valueOf: (key) => valueOf(state, key),
        devBuild,
        scope: "user",
        revision: state.revision,
      }),
    [devBuild, query, state],
  );
  const shown = useMemo(() => new Set(matches.flatMap((match) => match.rows.map((row) => row.key))), [matches]);
  const join = state.host?.devices_join ?? null;
  const places = useMemo(() => filterPlaces(query, joinConsentPlaces(join)), [join, query]);
  const shownPlaces = useMemo(() => new Set(places.map((place) => place.key)), [places]);
  // Pages the words name (their title, or the words of cards that draw no schema rows, such as
  // Devices' Screen sharing and Control): a link to each, above the rows.
  const pages = useMemo(() => filterPages({ query, devBuild }), [devBuild, query]);
  const router = useSettingsRouter();
  const empty = shown.size === 0 && places.length === 0 && pages.length === 0;
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
              <h2 className="result-section-title">{text(category.title)}</h2>
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
}
