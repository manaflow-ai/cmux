import { useSettingsState } from "../context";
import { searchRows } from "../search";
import { valueOf } from "../store";
import { t, text } from "../strings";
import { GroupList } from "./GroupList";

/** Matching rows from every section, editable in place, grouped by section. */
export function SearchResults({ query }: { query: string }) {
  const state = useSettingsState();
  const groups = searchRows(query, (key) => valueOf(state, key));
  if (groups.length === 0) return <p className="empty">{t("settingsPage.noResults")}</p>;
  return (
    <div className="search-results" data-search-results="">
      {groups.map(({ section, rows }) => (
        <section className="result-section" key={section.id} data-section={section.id}>
          <h2 className="result-section-title">{text(section.title)}</h2>
          <GroupList rows={rows} query={query} />
        </section>
      ))}
    </div>
  );
}
