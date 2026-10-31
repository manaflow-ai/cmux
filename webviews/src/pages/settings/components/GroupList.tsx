import { startTransition, useEffect, useState } from "react";
import type { CategoryGroup } from "../categories";
import { text } from "../strings";
import { SettingRow } from "./SettingRow";

/** Rows a category draws in its first frame: more than a tall window shows. */
const FIRST_FRAME_ROWS = 24;

/**
 * Whether this document has drawn a category yet. The first one draws whole: the host shows it only
 * once its first screen is in (paintGate.ts), and when the transition that adds the rest lost the
 * race with the user's values, the first frame shown had 24 rows and a short page that then grew
 * (test/settings-open-frames.test.ts). Opening another category later still draws 24 rows first.
 */
let drewFirstCategory = false;

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
  // Opening a category draws the rows a window can show (and the focused one) at once and the
  // rest in a transition after that frame, so a 123-row category opens at the cost of 24 rows.
  const focusIndex = focus ? groups.flatMap((group) => group.rows).findIndex((row) => row.key === focus) : -1;
  const [all, setAll] = useState(() => !drewFirstCategory);
  useEffect(() => {
    drewFirstCategory = true;
    if (!all) startTransition(() => setAll(true));
  }, [all]);
  const limit = shown || all ? Number.POSITIVE_INFINITY : Math.max(FIRST_FRAME_ROWS, focusIndex + 1);
  let before = 0;
  return groups.map((group) => {
    const first = before;
    before += group.rows.length;
    if (first >= limit) return null;
    const rows = group.rows.slice(0, limit - first);
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
            {rows.map((row) =>
              shown ? (
                <div className="collapse" key={row.key} data-open={shown.has(row.key) ? "" : undefined}>
                  <div className="collapse-body">
                    {(mounted?.has(row.key) ?? true) && (
                      // A row outside the filter highlights nothing, so its props stay equal and it
                      // skips the keystroke's render.
                      <SettingRow
                        row={row}
                        query={shown.has(row.key) ? query : undefined}
                        filtered={!shown.has(row.key)}
                      />
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
