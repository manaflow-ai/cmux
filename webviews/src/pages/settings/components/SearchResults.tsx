import { useSettingsState } from "../context";
import { filterRows } from "../search";
import { valueOf } from "../store";
import { t, text } from "../strings";
import { GroupList } from "./GroupList";

/** Matching (or changed) rows from every category, editable in place, grouped by category. */
export function SearchResults({ query, changedOnly = false }: { query: string; changedOnly?: boolean }) {
  const state = useSettingsState();
  const groups = filterRows({
    query,
    changedOnly,
    valueOf: (key) => valueOf(state, key),
    isChanged: (key) => state.rows.get(key)?.customized ?? false,
  });
  if (groups.length === 0)
    return (
      <p className="empty">
        {changedOnly && !query.trim() ? t("settingsPage.noChanged") : t("settingsPage.noResults")}
      </p>
    );
  return (
    <div className="search-results" data-search-results="">
      {groups.map(({ category, groups: matched }) => (
        <section className="result-section" key={category.id} data-section={category.id}>
          <h2 className="result-section-title">{text(category.title)}</h2>
          <GroupList groups={matched} query={query} />
        </section>
      ))}
    </div>
  );
}
