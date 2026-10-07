import { categories } from "../categories";
import { useSettingsState } from "../context";
import { filterRows } from "../search";
import { valueOf } from "../store";
import { t, text } from "../strings";
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
  });
  const shown = new Set(matches.flatMap((match) => match.rows.map((row) => row.key)));
  const empty = shown.size === 0;
  return (
    <div className="search-results" data-search-results="">
      <p className="empty collapse" data-open={empty ? "" : undefined}>
        <span className="collapse-body">
          {changedOnly && !query.trim() ? t("settingsPage.noChanged") : t("settingsPage.noResults")}
        </span>
      </p>
      {categories.map((category) => {
        const open = category.groups.some((group) => group.rows.some((row) => shown.has(row.key)));
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
              <GroupList groups={category.groups} query={query} shown={shown} />
            </div>
          </section>
        );
      })}
    </div>
  );
}
