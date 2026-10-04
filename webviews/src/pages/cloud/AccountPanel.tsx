// Account, plan, billing and usage. Billing opens checkout or the billing portal in the browser
// through the host's native action (a money action); no card data and no price logic in the page.
// Ops the owner does not serve yet (team list, sign-out, billing) show "Not available yet".
import type { Strings } from "../shared/i18n";
import { activeMachines } from "./model";
import { CloudOps } from "./ops";
import type { CloudState, CloudStore } from "./store";
import { format, L } from "./strings";

/** "12.5 h" or "12.5 h / 40 h", with the unit from the string table. */
function amount(
  value: number,
  limit: number | null | undefined,
  unit: string,
  t: (key: string) => string,
  language: string,
) {
  const number = new Intl.NumberFormat(language, { maximumFractionDigits: 1 });
  const text = (n: number) => format(t(unit), { value: number.format(n) });
  return limit === undefined || limit === null ? text(value) : `${text(value)} / ${text(limit)}`;
}

export function AccountPanel({ store, state, strings }: { store: CloudStore; state: CloudState; strings: Strings }) {
  const { t, language } = strings;
  const { auth, plan, usage, teams, unavailable } = state;
  const signOutUnavailable = unavailable.includes(CloudOps.authSignOut);
  const billingUnavailable = unavailable.includes(CloudOps.billingOpen);
  const used = plan?.activeVmCount ?? activeMachines(state.machines);
  return (
    <aside className="cloud-account" aria-label={t(L.plan)}>
      <div className="cloud-account-row">
        <button
          type="button"
          className="cloud-link-button cloud-signout-button"
          aria-disabled={signOutUnavailable}
          title={signOutUnavailable ? t(L.unavailable) : undefined}
          onClick={() => !signOutUnavailable && void store.signOut()}
        >
          {t(L.signOut)}
        </button>
        {signOutUnavailable && <span className="cloud-muted cloud-unavailable">{t(L.unavailable)}</span>}
      </div>
      {teams.length > 0 && (
        <label className="cloud-field cloud-team">
          <span className="cloud-field-label">{t(L.team)}</span>
          <select
            className="cloud-input cloud-team-select"
            value={auth?.team ?? ""}
            disabled={unavailable.includes(CloudOps.teamSelect)}
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
            <dd className="cloud-plan-name">{plan.planId ?? "-"}</dd>
            {plan.maxActiveVms !== undefined && plan.maxActiveVms !== null && (
              <>
                <dt>{t(L.machines)}</dt>
                <dd>{format(t(L.planMachines), { used, limit: plan.maxActiveVms })}</dd>
              </>
            )}
          </dl>
          <button
            type="button"
            className="cloud-button cloud-billing-button"
            aria-disabled={billingUnavailable}
            title={billingUnavailable ? t(L.unavailable) : undefined}
            onClick={() => !billingUnavailable && void store.openBilling()}
          >
            {t(plan.memoryUpgradePlanId ? L.upgrade : L.manageBilling)}
          </button>
          {billingUnavailable && <p className="cloud-muted cloud-unavailable">{t(L.unavailable)}</p>}
        </>
      )}
      {usage && usage.vmHoursUsed !== undefined && usage.vmHoursUsed !== null && (
        <>
          <h3 className="cloud-subsection-title">{t(L.usage)}</h3>
          <dl className="cloud-fields">
            <dt>{t(L.usageCompute)}</dt>
            <dd>{amount(usage.vmHoursUsed, usage.vmHoursIncluded, L.hours, t, language)}</dd>
          </dl>
        </>
      )}
    </aside>
  );
}
