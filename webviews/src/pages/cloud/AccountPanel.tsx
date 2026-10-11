// Account, plan and usage. `cloud.plan.get` answers the limits and the usage in one record; the page
// shows them as the backend reports them (machines, snapshots, compute hours) and computes no limit.
// "See plans" (Notices.tsx) links the public plans page until billing lands, then runs the checkout.
// Ops the owner does not serve yet (team list, sign-out) show "Not available yet".
import type { Strings } from "../shared/i18n";
import { percent } from "./model";
import { AccountOps } from "./ops";
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

function UsageRow({ label, used, limit, text }: { label: string; used: number; limit?: number | null; text: string }) {
  return (
    <div className="cloud-meter">
      <span className="cloud-meter-label">{label}</span>
      <span className="cloud-meter-track" aria-hidden="true">
        <span className="cloud-meter-fill" style={{ width: `${percent(used, limit) ?? 0}%` }} />
      </span>
      <span className="cloud-meter-text">{text}</span>
    </div>
  );
}

export function AccountPanel({ store, state, strings }: { store: CloudStore; state: CloudState; strings: Strings }) {
  const { t, language } = strings;
  const { auth, plan, teams, unavailable } = state;
  const signOutUnavailable = unavailable.includes(AccountOps.signOut);
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
            disabled={unavailable.includes(AccountOps.teamSelect)}
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
            <dd className="cloud-plan-name">{plan.plan_id}</dd>
          </dl>
          <h3 className="cloud-subsection-title">{t(L.usage)}</h3>
          <div className="cloud-stats cloud-usage">
            <UsageRow
              label={t(L.machines)}
              used={plan.usage.active}
              limit={plan.limits.max_active}
              text={format(t(L.planMachines), { used: plan.usage.active, limit: plan.limits.max_active })}
            />
            <UsageRow
              label={t(L.snapshots)}
              used={plan.usage.saved}
              limit={plan.limits.max_saved}
              text={format(t(L.planUsed), { used: plan.usage.saved, limit: plan.limits.max_saved })}
            />
            {plan.usage.vm_hours_used !== undefined && plan.usage.vm_hours_used !== null && (
              <UsageRow
                label={t(L.usageCompute)}
                used={plan.usage.vm_hours_used}
                limit={plan.limits.vm_hours_included}
                text={amount(plan.usage.vm_hours_used, plan.limits.vm_hours_included, L.hours, t, language)}
              />
            )}
          </div>
        </>
      )}
    </aside>
  );
}
