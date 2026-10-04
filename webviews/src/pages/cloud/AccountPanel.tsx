// Account, plan, billing and usage. Billing opens checkout or the billing portal in the browser
// through the host's native action (a money action); no card data and no price logic in the page.
import type { Strings } from "../shared/i18n";
import { formatDate } from "./model";
import type { CloudState, CloudStore } from "./store";
import { format, L } from "./strings";

function amount(value: number, limit: number | undefined, unit: string, language: string): string {
  const number = new Intl.NumberFormat(language, { maximumFractionDigits: 1 });
  return limit === undefined
    ? `${number.format(value)} ${unit}`
    : `${number.format(value)} / ${number.format(limit)} ${unit}`;
}

export function AccountPanel({ store, state, strings }: { store: CloudStore; state: CloudState; strings: Strings }) {
  const { t, language } = strings;
  const { auth, plan, usage, teams } = state;
  const used = state.machines.filter((machine) => machine.status !== "destroyed").length;
  return (
    <aside className="cloud-account" aria-label={t(L.plan)}>
      <div className="cloud-account-row">
        {auth?.email && <span className="cloud-account-email">{format(t(L.signedInAs), { email: auth.email })}</span>}
        <button type="button" className="cloud-link-button cloud-signout-button" onClick={() => void store.signOut()}>
          {t(L.signOut)}
        </button>
      </div>
      {teams.length > 0 && (
        <label className="cloud-field cloud-team">
          <span className="cloud-field-label">{t(L.team)}</span>
          <select
            className="cloud-input cloud-team-select"
            value={auth?.team ?? ""}
            onChange={(event) => void store.selectTeam(event.target.value)}
          >
            {teams.map((team) => (
              <option key={team.id} value={team.id}>
                {team.name}
              </option>
            ))}
          </select>
        </label>
      )}
      {plan && (
        <>
          <h3 className="cloud-subsection-title">{t(L.plan)}</h3>
          <dl className="cloud-fields">
            <dt>{t(L.plan)}</dt>
            <dd className="cloud-plan-name">{plan.name}</dd>
            <dt>{t(L.machines)}</dt>
            <dd>{format(t(L.planMachines), { used, limit: plan.machine_limit })}</dd>
          </dl>
          <button type="button" className="cloud-button cloud-billing-button" onClick={() => void store.openBilling()}>
            {t(plan.upgradable ? L.upgrade : L.manageBilling)}
          </button>
        </>
      )}
      {usage && (
        <>
          <h3 className="cloud-subsection-title">{t(L.usage)}</h3>
          <dl className="cloud-fields">
            <dt>{t(L.usagePeriod)}</dt>
            <dd>{`${formatDate(usage.period_start_ms, language, false)} – ${formatDate(usage.period_end_ms, language, false)}`}</dd>
            <dt>{t(L.usageCompute)}</dt>
            <dd>{amount(usage.compute_hours, usage.compute_hours_limit, "h", language)}</dd>
            <dt>{t(L.usageStorage)}</dt>
            <dd>{amount(usage.storage_gb, usage.storage_gb_limit, "GB", language)}</dd>
          </dl>
        </>
      )}
    </aside>
  );
}
