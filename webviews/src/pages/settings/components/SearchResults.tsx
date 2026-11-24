import { memo, useMemo, useState, lazy, Suspense } from "react";
import { categoryById, shownCategories, sidebarSections } from "../categories";
import { shallowEqual, useSettingsSelector, useStore, useSettingsRouter } from "../context";
import type { SettingsState } from "../store";
import { Icon } from "../icons";
import { CLOUD_MODELS_FOCUS, sectionHref } from "../router";
import { filterRows, filterPages, modelSettingsMatches } from "../search";
import { rowsByKey } from "../schema";
import { t, text } from "../strings";
import { CHIEF_PET_ROWS } from "../cardRows";
import { AskCmuxRow } from "./AskCmuxRow";
import { GroupList } from "./GroupList";

const searchInputs = (state: SettingsState) => ({
  rows: state.rows,
  revision: state.revision,
  devBuild: state.host?.dev_build === true,
});

// The Chief Pet card (and its characters' art) loads when a search first shows its rows, not with the page.
const ChiefPetCard = lazy(() => import("./ChiefPetCard").then(({ ChiefPetCard }) => ({ default: ChiefPetCard })));

/**
 * Matching rows from every category, editable in place, grouped by category. Every
 * row stays mounted while the filter is on: a row that stops matching collapses (height and
 * opacity) and one that starts matching opens, so the list never jumps between keystrokes.
 */
// A memo component: the page draws again on any change to its state (the host's lists among them),
// and the results take only the query.
export const SearchResults = memo(function SearchResults({ query }: { query: string }) {
  // Only what the filter reads: the values (a search finds a row by its value), the owner's
  // revision and whether the host is a DEV build. The host's lists, connectivity and every other
  // part of the page's state change without filtering again or drawing the results.
  const { rows, revision, devBuild } = useSettingsSelector(searchInputs, shallowEqual);
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
  // Pages the words name (their title, or the words of cards that draw no schema rows, such as
  // Devices' Screen sharing and Control): a link to each, above the rows.
  const modelMatches = modelSettingsMatches(query);
  const pages = useMemo(() => {
    const hits = filterPages({ query, devBuild });
    return modelMatches.models && !hits.some((page) => page.id === "models") ? [categoryById("models"), ...hits] : hits;
  }, [devBuild, modelMatches.models, query]);
  const router = useSettingsRouter();
  const empty = shown.size === 0 && pages.length === 0 && !modelMatches.cloud;
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
      {(pages.length > 0 || modelMatches.cloud) && (
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
          {modelMatches.cloud && (
            <button
              type="button"
              className="ask-cmux search-page"
              data-page-hit="cloudModels"
              onClick={() => router.history.push(sectionHref("cloud", CLOUD_MODELS_FOCUS))}
            >
              <Icon name="arrow.turn.down.right" />
              <span className="ask-cmux-text">
                <span className="ask-cmux-title">{t("settingsWindow.cloud.models.title")}</span>
                <span className="ask-cmux-words">{text(categoryById("cloud").title)}</span>
              </span>
            </button>
          )}
        </div>
      )}
      {categories.map((category) => {
        const open = category.groups.some((group) => group.rows.some((row) => shown.has(row.key)));
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
              <GroupList groups={groups} query={query} shown={shown} mounted={mounted} />
            </div>
          </section>
        );
      })}
    </div>
  );
});
