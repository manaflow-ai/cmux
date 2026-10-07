import { groupRows, type SchemaRow } from "../schema";
import { text } from "../strings";
import { SettingRow } from "./SettingRow";

/** Rows under their group titles, separated by spacing and hairlines; no fills. */
export function GroupList({ rows, query, focus }: { rows: SchemaRow[]; query?: string; focus?: string | null }) {
  return groupRows(rows).map((group) => (
    <section className="group" key={group.key}>
      <h3 className="group-title">{text(group.title)}</h3>
      <div className="rows">
        {group.rows.map((row) => (
          <SettingRow key={row.key} row={row} query={query} focused={row.key === focus} />
        ))}
      </div>
    </section>
  ));
}
