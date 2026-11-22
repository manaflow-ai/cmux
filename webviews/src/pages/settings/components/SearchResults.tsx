import { lazy, Suspense, useMemo, useState } from "react";
import { shownCategories } from "../categories";
import { useSettingsState, useStore } from "../context";
import { filterRows } from "../search";
import { valueOf } from "../store";
import { t, text } from "../strings";
import { CHIEF_PET_ROWS } from "../cardRows";
import { AskCmuxRow } from "./AskCmuxRow";
import { GroupList } from "./GroupList";

// The Chief Pet card (and its characters' art) loads when a search first shows its rows, not with the page.
const ChiefPetCard = lazy(() => import("./ChiefPetCard").then(({ ChiefPetCard }) => ({ default: ChiefPetCard })));

/**
 * Matching rows from every category, editable in place, grouped by category. Every
 * row stays mounted while the filter is on: a row that stops matching collapses (height and
 * opacity) and one that starts matching opens, so the list never jumps between keystrokes.
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
  const empty = shown.size === 0;
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
}
