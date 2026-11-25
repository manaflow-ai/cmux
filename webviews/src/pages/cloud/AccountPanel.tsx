// Account, plan and usage. `cloud.plan.get` answers the limits and the usage in one record; the page
// shows them as the backend reports them (machines, snapshots, compute hours, the team's spend against its
// spending cap) and computes no limit.
// "See plans" (Notices.tsx) links the public plans page until billing lands, then runs the checkout.
// Ops the owner does not serve yet (team list, sign-out) show "Not available yet".
// A failed renewal (the app's `cmux.cloud.billing.status` answers true) shows one line under the plan
// with Manage Billing; any other answer, a failed read or a signed-out account shows nothing.
// This month (`cloud.usage.current`): the total and each meter with the billing owner's dollars, when it was
// counted, uncounted spans, the card on file ("Add payment method" runs the checkout; "Change" opens billing),
// and "Test mode" while payments run in test mode. A server that does not serve it shows nothing.
import { useState } from "react";
import type { Strings } from "../shared/i18n";
import { Switch } from "../../ui/Switch";
import { percent } from "./model";
import { AccountOps, CloudOps, type CloudRetention, type RetentionOverrides } from "./ops";
import { RETENTION_FIELDS, retentionLimit, type RetentionField } from "./retention";
import { clockTime, usd } from "./spendCap";
import { cardBrand, hasGaps, meterAmount, monthTotal, quantity, testMode, type UsageMeter } from "./usage";
import type { CloudState, CloudStore } from "./store";
import { format, L } from "./strings";
import { intl } from "../../ui/intl";

/** "12.5 h" or "12.5 h / 40 h", with the unit from the string table. */
function amount(
  value: number,
  limit: number | null | undefined,
  unit: string,
  t: (key: string) => string,
  language: string,
) {
  const number = intl.NumberFormat(language, { maximumFractionDigits: 1 });
  const text = (n: number) => format(t(unit), { value: number.format(n) });
  return limit === undefined || limit === null ? text(value) : `${text(value)} / ${text(limit)}`;
}

/**
 * A catalog float64 the page can show: a number. The catalog encodes non-finite values as strings
 * ("Infinity"); the app server sends those as null, and the page shows neither.
 */
function finite(value: number | string | null | undefined): number | undefined {
  return typeof value === "number" ? value : undefined;
}

/** The failed-payment line with Manage Billing (the app's `billing.openPortal`). */
function PaymentPastDue({ store, t }: { store: CloudStore; t: (key: string) => string }) {
  return (
    <div className="cloud-past-due" role="status">
      <span className="cloud-past-due-text">{t(L.planPastDue)}</span>
      <button type="button" className="cloud-button cloud-manage-billing" onClick={() => void store.manageBilling()}>
        {t(L.planManageBilling)}
      </button>
    </div>
  );
}

const METERS: { meter: UsageMeter; label: string; unit: string }[] = [
  { meter: "vcpu", label: L.usageVcpu, unit: L.usageVcpuHours },
  { meter: "memory", label: L.usageMemory, unit: L.usageGibHours },
  { meter: "stored", label: L.usageStored, unit: L.usageGibMonths },
];

/** This month's usage and its cost, and the payment method on file. */
function MonthUsage({ store, state, strings }: { store: CloudStore; state: CloudState; strings: Strings }) {
  const { t, language } = strings;
  const { usage } = state;
  if (state.unavailable.includes(CloudOps.usageCurrent)) return null;
  if (!usage) {
    return (
      <section className="cloud-month" aria-label={t(L.usageMonth)} aria-busy={!state.usageFailed}>
        <div className="cloud-month-head">
          <span className="cloud-month-title">{t(L.usageMonth)}</span>
        </div>
        {state.usageFailed ? (
          <div className="cloud-month-failed" role="alert">
            <span className="cloud-muted">{t(L.usageFailed)}</span>
            <button
              type="button"
              className="cloud-link-button cloud-month-retry"
              onClick={() => void store.retryUsage()}
            >
              {t(L.retry)}
            </button>
          </div>
        ) : (
          <span className="cloud-muted cloud-month-loading">{t(L.loading)}</span>
        )}
      </section>
    );
  }
  const brand = cardBrand(usage.payment_method.brand);
  const digits = usage.payment_method.last4 ?? undefined;
  return (
    <section className="cloud-month" aria-label={t(L.usageMonth)}>
      <div className="cloud-month-head">
        <span className="cloud-month-title">{t(L.usageMonth)}</span>
        {testMode(usage) && <span className="cloud-month-test">{t(L.usageTestMode)}</span>}
        <span className="cloud-month-total">{usd(monthTotal(usage), language)}</span>
      </div>
      <dl className="cloud-month-lines">
        {METERS.map(({ meter, label, unit }) => {
          const { amount, usd: dollars } = meterAmount(usage, meter);
          return (
            <div key={meter} className={`cloud-month-line cloud-month-${meter}`}>
              <dt>{t(label)}</dt>
              <dd className="cloud-month-amount">{format(t(unit), { value: quantity(amount, language) })}</dd>
              <dd className="cloud-month-usd">{usd(dollars, language)}</dd>
            </div>
          );
        })}
      </dl>
      <p className="cloud-muted cloud-month-asof">
        {format(t(L.usageAsOf), { time: clockTime(usage.as_of, language) })}
        {hasGaps(usage) && <span className="cloud-month-gaps"> · {t(L.usageGaps)}</span>}
      </p>
      <div className="cloud-month-payment">
        {usage.payment_method.attached ? (
          <>
            <span className="cloud-month-card">
              {brand && digits ? format(t(L.paymentCard), { brand, digits }) : (brand ?? "")}
            </span>
            {(brand || digits) && <span className="cloud-muted"> · </span>}
            <button
              type="button"
              className="cloud-link-button cloud-month-change"
              onClick={() => void store.manageBilling()}
            >
              {t(L.paymentChange)}
            </button>
          </>
        ) : state.paymentOff ? (
          <span className="cloud-muted">{t(L.paymentOff)}</span>
        ) : (
          <button type="button" className="cloud-button cloud-month-add" onClick={() => void store.addPaymentMethod()}>
            {t(L.paymentAdd)}
          </button>
        )}
      </div>
    </section>
  );
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
  const hoursUsed = finite(plan?.usage.vm_hours_used);
  const hoursIncluded = finite(plan?.limits.vm_hours_included);
  // The team's spend against its spending cap this period (cloud.plan.get `spend_cap`, absent without the cap).
  const capSpent = finite(plan?.spend_cap?.spent_usd);
  const capLimit = finite(plan?.spend_cap?.cap_usd);
  return (
    <aside className="cloud-account" aria-label={t(L.plan)}>
      <div className="cloud-account-row">
        <button
          type="button"
          className="cloud-link-button cloud-signout-button"
          aria-disabled={signOutUnavailable}
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
      {!plan && state.paymentPastDue && <PaymentPastDue store={store} t={t} />}
      {plan && (
        <>
          <h3 className="cloud-subsection-title">{t(L.plan)}</h3>
          <dl className="cloud-fields">
            <dt>{t(L.plan)}</dt>
            <dd className="cloud-plan-name">{plan.plan_id}</dd>
          </dl>
          {state.paymentPastDue && <PaymentPastDue store={store} t={t} />}
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
            {capSpent !== undefined && capLimit !== undefined && (
              <UsageRow
                label={t(L.capTeamSpend)}
                used={capSpent}
                limit={capLimit}
                text={`${usd(capSpent, language)} / ${usd(capLimit, language)}`}
              />
            )}
            {hoursUsed !== undefined && (
              <UsageRow
                label={t(L.usageCompute)}
                used={hoursUsed}
                limit={hoursIncluded}
                text={amount(hoursUsed, hoursIncluded, L.hours, t, language)}
              />
            )}
          </div>
          <MonthUsage store={store} state={state} strings={strings} />
          {plan.retention && !unavailable.includes(CloudOps.retentionSet) && (
            <CleanupSettings store={store} state={state} retention={plan.retention} strings={strings} />
          )}
        </>
      )}
    </aside>
  );
}

const FIELD_LABEL: Record<RetentionField, string> = {
  never_used_hours: L.cleanupNeverUsed,
  failed_create_hours: L.cleanupFailed,
  worked_in_days: L.cleanupWorkedIn,
  heads_up_days: L.cleanupHeadsUp,
  archive_days: L.cleanupArchive,
};

/**
 * Cloud settings' cleanup (cmux-platform Retention.ts): what the plan does with unused machines, the
 * caller's one email heads-up (on by default; the in-app notice comes either way), and the team's own
 * numbers within the plan's limits. Only a team admin may save those; anyone else is told so on Save.
 */
function CleanupSettings({
  store,
  state,
  retention,
  strings,
}: {
  store: CloudStore;
  state: CloudState;
  retention: CloudRetention;
  strings: Strings;
}) {
  const { t } = strings;
  const settings = retention.settings;
  const [draft, setDraft] = useState<Partial<Record<RetentionField, string>>>({});
  const saving = !!state.retention?.saving;
  // A paid plan keeps worked-in machines: the unused window is not the team's to set there.
  const fields = RETENTION_FIELDS.filter((field) => field !== "worked_in_days" || settings?.worked_in_days != null);
  const shown = (field: RetentionField) => draft[field] ?? String(retention.team[field] ?? settings?.[field] ?? "");
  const save = () => {
    const out: Record<string, number> = { ...(retention.team as Record<string, number>) };
    for (const field of fields) {
      const value = Number(draft[field] ?? NaN);
      if (draft[field] !== undefined && Number.isInteger(value)) out[field] = value;
    }
    void store.setTeamRetention(out as RetentionOverrides);
    setDraft({});
  };
  return (
    <>
      <h3 className="cloud-subsection-title">{t(L.cleanupTitle)}</h3>
      {settings && (
        <p className="cloud-muted cloud-cleanup-policy">
          {settings.worked_in_days == null
            ? format(t(L.cleanupPolicyKept), {
                failed: settings.failed_create_hours,
                never: settings.never_used_hours,
              })
            : format(t(L.cleanupPolicyRetained), {
                days: settings.worked_in_days,
                headsUp: settings.heads_up_days,
                failed: settings.failed_create_hours,
                never: settings.never_used_hours,
              })}
        </p>
      )}
      <label className="cloud-check cloud-cleanup-email">
        <Switch
          size="sm"
          aria-label={t(L.cleanupEmail)}
          checked={retention.email_heads_up}
          disabled={saving}
          onCheckedChange={(on) => void store.setEmailHeadsUp(on)}
        />
        <span>{t(L.cleanupEmail)}</span>
      </label>
      {settings && (
        <details className="cloud-cleanup-team">
          <summary>{t(L.cleanupTeam)}</summary>
          <div className="cloud-cleanup-fields">
            {fields.map((field) => {
              const { min, max } = retentionLimit(field);
              // A team may clean up sooner, never keep longer than its plan.
              const limit = field === "worked_in_days" ? Math.min(max, settings.worked_in_days ?? max) : max;
              return (
                <label key={field} className="cloud-field cloud-cleanup-field">
                  <span className="cloud-field-label">{t(FIELD_LABEL[field])}</span>
                  <input
                    className="cloud-input"
                    aria-label={t(FIELD_LABEL[field])}
                    type="number"
                    min={min}
                    max={limit}
                    step={1}
                    value={shown(field)}
                    disabled={saving}
                    onChange={(event) => setDraft({ ...draft, [field]: event.target.value })}
                  />
                </label>
              );
            })}
          </div>
          {state.retention?.forbidden && (
            <output className="cloud-muted cloud-cleanup-admin">{t(L.cleanupAdminOnly)}</output>
          )}
          {state.retention?.error && (
            <p className="cloud-sheet-error" role="alert">
              {t(L.actionFailed)} <span className="cloud-error-detail">{state.retention.error}</span>
            </p>
          )}
          <div className="cloud-item-actions">
            <button
              type="button"
              className="cloud-link-button cloud-cleanup-reset"
              disabled={saving || Object.keys(retention.team).length === 0}
              onClick={() => void store.setTeamRetention(null)}
            >
              {t(L.cleanupReset)}
            </button>
            <button
              type="button"
              className="cloud-button cloud-cleanup-save"
              disabled={saving || Object.keys(draft).length === 0}
              onClick={save}
            >
              {t(L.save)}
            </button>
          </div>
        </details>
      )}
    </>
  );
}
