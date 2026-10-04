// Account, plan, billing and usage. Billing opens checkout or the billing portal in the browser
// through the host's native action (a money action); no card data and no price logic in the page.
import type { Strings } from "../shared/i18n";
import { formatDate } from "./model";
import type { CloudState, CloudStore } from "./store";
import { format, L } from "./strings";

/** "42.5 h" or "42.5 h / 300 h", with the unit from the string table. */
function amount(value: number, limit: number | undefined, unit: string, t: (key: string) => string, language: string) {
  const number = new Intl.NumberFormat(language, { maximumFractionDigits: 1 });
  const text = (n: number) => format(t(unit), { value: number.format(n) });
  return limit === undefined ? text(value) : `${text(value)} / ${text(limit)}`;
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
            onChange={(event) => event.target.value && void store.selectTeam(event.target.value)}
          >
            {!teams.some((team) => team.id === auth?.team) && <option value="">{t(L.team)}</option>}
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
            <dd>
              {format(t(L.usageRange), {
                start: formatDate(usage.period_start_ms, language, false),
                end: formatDate(usage.period_end_ms, language, false),
              })}
            </dd>
            <dt>{t(L.usageCompute)}</dt>
            <dd>{amount(usage.compute_hours, usage.compute_hours_limit, L.hours, t, language)}</dd>
            <dt>{t(L.usageStorage)}</dt>
            <dd>{amount(usage.storage_gb, usage.storage_gb_limit, L.gigabytes, t, language)}</dd>
          </dl>
        </>
      )}
    </aside>
  );
}
