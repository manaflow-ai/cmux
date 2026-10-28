import { useState } from "react";
import { shownCategories } from "../categories";
import { useSettingsState } from "../context";
import { filterRows } from "../search";
import { valueOf } from "../store";
import { t, text } from "../strings";
import { CHIEF_PET_ROWS, ChiefPetCard } from "./ChiefPetCard";
import { GroupList } from "./GroupList";

/**
 * Matching (or changed) rows from every category, editable in place, grouped by category. Every
 * row stays mounted while the filter is on: a row that stops matching collapses (height and
 * opacity) and one that starts matching opens, so the list never jumps between keystrokes.
 */
export function SearchResults({ query, changedOnly = false }: { query: string; changedOnly?: boolean }) {
  const state = useSettingsState();
  const matches = filterRows({
    query,
    changedOnly,
    valueOf: (key) => valueOf(state, key),
    isChanged: (key) => state.rows.get(key)?.customized ?? false,
    devBuild: state.host?.dev_build === true,
  });
  const shown = new Set(matches.flatMap((match) => match.rows.map((row) => row.key)));
  const empty = shown.size === 0;
  // Only rows that matched at some point in this search mount their editors (a row that stops
  // matching keeps its content to collapse smoothly); the rest stay empty, collapsed slots, so
  // opening search costs the matches, not every setting.
  const [mounted, setMounted] = useState<ReadonlySet<string>>(shown);
  if ([...shown].some((key) => !mounted.has(key))) setMounted(new Set([...mounted, ...shown]));
  return (
    <div className="search-results" data-search-results="">
      <p className="empty collapse" data-open={empty ? "" : undefined}>
        <span className="collapse-body">
          {changedOnly && !query.trim() ? t("settingsPage.noChanged") : t("settingsPage.noResults")}
        </span>
      </p>
      {shownCategories(state.host?.dev_build === true).map((category) => {
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
              {petRows && petRows.size > 0 && <ChiefPetCard query={query} visibleRows={petRows} />}
              <GroupList groups={groups} query={query} shown={shown} mounted={mounted} />
            </div>
          </section>
        );
      })}
    </div>
  );
}
