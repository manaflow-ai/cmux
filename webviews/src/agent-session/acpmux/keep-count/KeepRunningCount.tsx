import { Switch } from "../../../ui/Switch";
import { useT } from "../i18n";
import { countLine, hoursLine, hoursShare, type KeepCount, MAX_PIPS, nextLine } from "./keepCount";
import "./keepRunningCount.css";

/// How the count draws beside the keep-running switch (KeepRunningCount.gallery.tsx compares them):
/// - `inline`: "2 of 3" on the switch's own row, the hours and what flipping it does under it, one
///   quiet line;
/// - `stack`: the switch row, then "2 of 3 kept running, 41 of 100 hours used" and the next line;
/// - `meter`: the switch row, then one dot a slot and an hours bar, and the next line.
export type KeepCountLook = "inline" | "stack" | "meter";

/// The count under (or on) the keep-running switch's row. `on` and `onChange` are the switch's own
/// (its owner, the hybrid-chats cloud control, keeps them); the count only reads `count`.
export function KeepRunningCount({
  count,
  look = "stack",
  on,
  onChange,
}: {
  count: KeepCount;
  look?: KeepCountLook;
  on: boolean;
  onChange?(on: boolean): void;
}) {
  const t = useT();
  const kept = countLine(count);
  const hours = hoursLine(count);
  const next = nextLine(count);
  const name = t("keepCount.switch");
  const warn = count.next.do === "full" || count.next.do === "hoursUsedUp";
  const share = hoursShare(count);
  return (
    <div className="acpmux-keep-count" data-look={look} data-testid="keep-running-count">
      <label className="acpmux-keep-count__row">
        <span className="acpmux-keep-count__name">{name}</span>
        {look === "inline" && count.plan !== null && (
          <span className="acpmux-keep-count__short" data-warn={warn || undefined}>
            {t("keepCount.short", { kept: count.kept, slots: count.slots })}
          </span>
        )}
        <Switch size="md" aria-label={name} checked={on} onCheckedChange={(value) => onChange?.(value)} />
      </label>
      {look === "stack" && (kept || hours) && (
        <div className="acpmux-keep-count__count" data-warn={warn || undefined}>
          {kept && t(kept.key, kept.values)}
          {kept && hours && t("keepCount.join")}
          {hours && <span data-low={count.hoursLow || undefined}>{t(hours.key, hours.values)}</span>}
        </div>
      )}
      {look === "meter" && count.plan !== null && (
        <div className="acpmux-keep-count__meter">
          <span className="acpmux-keep-count__gauge" aria-label={kept && t(kept.key, kept.values)}>
            {count.slots <= MAX_PIPS ? (
              <span className="acpmux-keep-count__pips" aria-hidden="true">
                {Array.from({ length: count.slots }, (_, index) => (
                  <i key={index} data-on={index < count.kept || undefined} />
                ))}
              </span>
            ) : (
              <span className="acpmux-keep-count__bar" aria-hidden="true">
                <i style={{ width: `${Math.min(100, (count.kept / Math.max(1, count.slots)) * 100)}%` }} />
              </span>
            )}
            <span className="acpmux-keep-count__figure" data-warn={warn || undefined}>
              {t("keepCount.short", { kept: count.kept, slots: count.slots })}
            </span>
          </span>
          {share !== undefined && hours && (
            <span className="acpmux-keep-count__gauge" aria-label={t(hours.key, hours.values)}>
              <span className="acpmux-keep-count__bar" data-low={count.hoursLow || undefined} aria-hidden="true">
                <i style={{ width: `${share * 100}%` }} />
              </span>
              <span className="acpmux-keep-count__figure" data-low={count.hoursLow || undefined}>
                {t(hours.key, hours.values)}
              </span>
            </span>
          )}
        </div>
      )}
      <div className="acpmux-keep-count__next">
        {look === "inline" && hours && (
          <>
            <span data-low={count.hoursLow || undefined}>{t(hours.key, hours.values)}</span>
            {t("keepCount.join")}
          </>
        )}
        {t(next.key, next.values)}
      </div>
    </div>
  );
}
