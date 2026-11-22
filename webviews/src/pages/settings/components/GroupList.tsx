import type { CategoryGroup } from "../categories";
import { text } from "../strings";
import { SettingRow } from "./SettingRow";

/**
 * Rows under their group titles, separated by spacing and hairlines; no fills. With `shown` (a
 * filter), rows and groups outside it collapse in place instead of unmounting.
 */
export function GroupList({
  groups,
  query,
  focus,
  shown,
  mounted,
}: {
  groups: CategoryGroup[];
  query?: string;
  focus?: string | null;
  shown?: ReadonlySet<string>;
  /** With a filter: the rows that draw their editors (the rest are empty collapsed slots). */
  mounted?: ReadonlySet<string>;
}) {
  return groups.map((group) => {
    const open = !shown || group.rows.some((row) => shown.has(row.key));
    return (
      <section
        className={shown ? "group collapse" : "group"}
        key={group.key}
        data-group={group.key}
        data-open={shown && open ? "" : undefined}
      >
        <div className={shown ? "collapse-body" : undefined}>
          <h3 className="group-title">{text(group.title)}</h3>
          <div className="rows">
            {group.rows.map((row) =>
              shown ? (
                <div className="collapse" key={row.key} data-open={shown.has(row.key) ? "" : undefined}>
                  <div className="collapse-body">
                    {(mounted?.has(row.key) ?? true) && (
                      <SettingRow row={row} query={query} filtered={!shown.has(row.key)} />
                    )}
                  </div>
                </div>
              ) : (
                <SettingRow key={row.key} row={row} query={query} focused={row.key === focus} />
              ),
            )}
          </div>
        </div>
      </section>
    );
  });
}
