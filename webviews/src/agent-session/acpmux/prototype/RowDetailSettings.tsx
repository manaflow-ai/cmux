// The row-detail setting (#16688) as the Settings window would show it: a level, then each item.
// Classic cmux shows it disabled, since it keeps rows minimal.
import { ROW_DETAIL_ITEMS, type RowDetailItem, type RowDetailItems, type RowDetailLevel } from "./rowDetail";

const ROW_DETAIL_LABELS: Record<RowDetailItem, string> = {
  preview: "Last message and age",
  pullRequest: "Pull request and checks",
  branch: "Branch",
  agents: "Agents and their status",
  groupByStatus: "Group by status",
};

export function RowDetailSettings({
  level,
  items,
  locked,
  onLevel,
  onItem,
}: {
  level: RowDetailLevel;
  items: RowDetailItems;
  locked: boolean;
  onLevel: (level: RowDetailLevel) => void;
  onItem: (item: RowDetailItem, on: boolean) => void;
}) {
  return (
    <section id="proto-row-detail" className="proto-row-settings" aria-labelledby="proto-row-detail-title">
      <h2 id="proto-row-detail-title">Row detail</h2>
      <fieldset disabled={locked}>
        <legend className="acpmux-hidden-label">Level</legend>
        <div className="proto-row-levels">
          {(["minimal", "standard", "everything"] as const).map((option) => (
            <label key={option} htmlFor={`row-detail-${option}`} className={option === level ? "is-on" : undefined}>
              <input
                id={`row-detail-${option}`}
                aria-label={option}
                type="radio"
                name="row-detail-level"
                checked={!locked && option === level}
                onChange={() => onLevel(option)}
              />
              {option[0]!.toUpperCase() + option.slice(1)}
            </label>
          ))}
        </div>
        {ROW_DETAIL_ITEMS.map((item) => (
          <label key={item} htmlFor={`row-detail-${item}`} className="proto-row-toggle">
            <input
              id={`row-detail-${item}`}
              aria-label={ROW_DETAIL_LABELS[item]}
              type="checkbox"
              checked={items[item]}
              onChange={(event) => onItem(item, event.target.checked)}
            />
            {ROW_DETAIL_LABELS[item]}
          </label>
        ))}
      </fieldset>
      {locked && <p>Classic cmux keeps rows minimal.</p>}
    </section>
  );
}
