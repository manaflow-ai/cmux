// The Chief Usage page (cmux-page://cmux.chief-usage/, plans/cmux-next/chief-usage-analytics-DESIGN.md):
// token use, cost, cache hit and turn time of this Mac's Chiefs over time, from their usage
// ledgers. The header picks the window and the breakdown's grouping and reads again on Refresh;
// the body is a design (the shipped one is Ledger; the gallery shows the others).
import { useSyncExternalStore, type ComponentType } from "react";
import type { Strings } from "../shared/i18n";
import type { DesignProps } from "./designs/DesignProps";
import { LedgerDesign } from "./designs/LedgerDesign";
import { tokenTotal } from "./shape";
import type { ChiefUsageStore } from "./store";
import { BY_KEYS, WINDOWS, type UsageBy } from "./types";

export function ChiefUsagePage({
  store,
  strings,
  design: Design = LedgerDesign,
}: {
  store: ChiefUsageStore;
  strings: Strings;
  design?: ComponentType<DesignProps>;
}) {
  const snapshot = useSyncExternalStore(store.subscribe, store.getSnapshot);
  const { summary, window, by } = snapshot;

  if (snapshot.unavailable) return <p className="cu-message">{strings.t("chiefUsage.page.unavailable")}</p>;

  const empty = summary && summary.totals.units === 0 && tokenTotal(summary.totals) === 0;
  return (
    <div className="cu" aria-busy={snapshot.loading}>
      <header className="cu-header">
        <h1 className="cu-title">{strings.t("chiefUsage.page.title")}</h1>
        <div className="cu-controls">
          <fieldset className="cu-segmented" aria-label={strings.t("chiefUsage.window.label")}>
            {WINDOWS.map((option) => (
              <button
                key={option}
                type="button"
                aria-pressed={option === window}
                className={
                  option === window ? "cu-segment-button cu-window is-selected" : "cu-segment-button cu-window"
                }
                data-window={option}
                onClick={() => void store.setWindow(option)}
              >
                {strings.t(`chiefUsage.window.${option}`)}
              </button>
            ))}
          </fieldset>
          <label className="cu-by">
            <span>{strings.t("chiefUsage.by.label")}</span>
            <select value={by} onChange={(event) => void store.setBy(event.currentTarget.value as UsageBy)}>
              {BY_KEYS.map((option) => (
                <option key={option} value={option}>
                  {strings.t(`chiefUsage.by.${option}`)}
                </option>
              ))}
            </select>
          </label>
          <button type="button" className="cu-refresh" disabled={snapshot.loading} onClick={() => void store.refresh()}>
            {strings.t("chiefUsage.page.refresh")}
          </button>
        </div>
      </header>
      {snapshot.failed ? (
        <p className="cu-message">{snapshot.failed.message ?? strings.t("chiefUsage.page.failed")}</p>
      ) : !summary ? (
        <p className="cu-message cu-muted">{strings.t("chiefUsage.page.loading")}</p>
      ) : (
        <>
          {empty && <p className="cu-message cu-muted">{strings.t("chiefUsage.page.empty")}</p>}
          <Design summary={summary} by={by} strings={strings} />
        </>
      )}
    </div>
  );
}
