// The plan's hours and the monthly spend limit past them (RFD 0081; pool.ts). Shown in the account panel only when
// the default-off switch is on and `cloud.plan.get` sends a `pool`. The backend decides the warning and whether
// machines may run; the panel words them and saves the limit through the host's confirmation.
import { useState } from "react";
import type { Strings } from "../shared/i18n";
import { intl } from "../../ui/intl";
import { hourRateUsd, hoursFor, hoursOf, parseSpendLimit, poolState, type PoolStanding } from "./pool";
import { day, usd } from "./spendCap";
import type { CloudState, CloudStore } from "./store";
import { format, L } from "./strings";

export function PoolPanel({
  store,
  state,
  pool,
  strings,
}: {
  store: CloudStore;
  state: CloudState;
  pool: PoolStanding;
  strings: Strings;
}) {
  const { t, language } = strings;
  const [draft, setDraft] = useState<string | undefined>(undefined);
  const hours = intl.NumberFormat(language, { maximumFractionDigits: 0 });
  const status = poolState(pool);
  const used = hoursOf(pool.used_minutes, pool);
  const included = hoursOf(pool.included_minutes, pool);
  const fill = Math.min(100, Math.max(0, pool.percent));
  const saving = !!state.spendLimit?.saving;
  const shown = draft ?? String(pool.spend_limit_usd);
  const parsed = parseSpendLimit(shown);
  const changed = draft !== undefined && parsed !== null && parsed !== pool.spend_limit_usd;
  const buys = parsed !== null && parsed > 0 ? hoursFor(parsed, pool) : 0;
  const save = () => {
    if (parsed === null || !changed) return;
    void store.setSpendLimit(parsed).then(() => setDraft(undefined));
  };
  return (
    <section className="cloud-pool" data-state={status} aria-label={t(L.poolTitle)}>
      <h3 className="cloud-subsection-title">{t(L.poolTitle)}</h3>
      <div
        className="cloud-pool-track"
        role="meter"
        aria-valuemin={0}
        aria-valuemax={100}
        aria-valuenow={fill}
        aria-label={t(L.poolTitle)}
      >
        <span className="cloud-pool-fill" style={{ width: `${fill}%` }} />
        <span className="cloud-pool-mark" style={{ insetInlineStart: "80%" }} aria-hidden="true" />
      </div>
      <p className="cloud-pool-used">
        {format(t(L.poolUsed), { used: hours.format(Math.floor(used)), included: hours.format(included) })}
        {pool.period_end ? (
          <span className="cloud-muted"> {format(t(L.poolResets), { date: day(pool.period_end, language) })}</span>
        ) : null}
      </p>
      {status === "near" && (
        <div className="cloud-pool-alert" role="status">
          <strong>{t(L.poolNear)}</strong>
          <span>{t(L.poolNearBody)}</span>
        </div>
      )}
      {status === "overage" && (
        <div className="cloud-pool-alert" role="status">
          <strong>
            {format(t(L.poolOverage), {
              spent: usd(pool.overage_usd, language),
              limit: usd(pool.spend_limit_usd, language),
            })}
          </strong>
        </div>
      )}
      {status === "paused" && (
        <div className="cloud-pool-alert cloud-pool-alert-bad" role="alert">
          <strong>{t(L.poolPaused)}</strong>
          <span>{t(L.poolPausedBody)}</span>
        </div>
      )}
      <label className="cloud-field cloud-pool-limit">
        <span className="cloud-field-label">{t(L.poolLimit)}</span>
        <span className="cloud-pool-limit-row">
          <span className="cloud-pool-currency" aria-hidden="true">
            $
          </span>
          <input
            className="cloud-input cloud-pool-input"
            aria-label={t(L.poolLimit)}
            aria-invalid={parsed === null}
            inputMode="decimal"
            value={shown}
            disabled={saving}
            onChange={(event) => setDraft(event.target.value)}
            onKeyDown={(event) => event.key === "Enter" && save()}
          />
          <button type="button" className="cloud-button cloud-pool-save" disabled={saving || !changed} onClick={save}>
            {t(L.save)}
          </button>
        </span>
      </label>
      {parsed === null ? (
        <p className="cloud-sheet-error" role="alert">
          {t(L.poolLimitInvalid)}
        </p>
      ) : (
        <p className="cloud-muted cloud-pool-hint">
          {format(t(L.poolLimitHint), { rate: usd(hourRateUsd(pool), language) })}
          {buys > 0 && <> {format(t(L.poolLimitBuys), { hours: hours.format(buys) })}</>}
        </p>
      )}
      {state.spendLimit?.forbidden && <output className="cloud-muted">{t(L.poolLimitAdminOnly)}</output>}
      {state.spendLimit?.error && (
        <p className="cloud-sheet-error" role="alert">
          {t(L.actionFailed)} <span className="cloud-error-detail">{state.spendLimit.error}</span>
        </p>
      )}
    </section>
  );
}
