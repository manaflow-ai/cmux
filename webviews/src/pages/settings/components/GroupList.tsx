import type { CategoryGroup } from "../categories";
import { text } from "../strings";
import { SettingRow } from "./SettingRow";

/** Rows under their group titles, separated by spacing and hairlines; no fills. */
export function GroupList({
  groups,
  query,
  focus,
}: {
  groups: CategoryGroup[];
  query?: string;
  focus?: string | null;
}) {
  return groups.map((group) => (
    <section className="group" key={group.key} data-group={group.key}>
      <h3 className="group-title">{text(group.title)}</h3>
      <div className="rows">
        {group.rows.map((row) => (
          <SettingRow key={row.key} row={row} query={query} focused={row.key === focus} />
        ))}
      </div>
    </section>
  ));
}
