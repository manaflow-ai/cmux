// Two notices: the one-time banner for machines from cmux Cloud classic (contract 4: "Move them"
// runs `cloud.migration.start` as a native action, "Later" hides it for this page session), and a
// typed plan refusal (contract 1.5: `plan_required`, `quota_exceeded {limit, used}`, `size_locked`)
// as a localized sentence with "See plans", which runs `cloud.billing.checkout {plan}` natively.
import type { Strings } from "../shared/i18n";
import { migrationBanner } from "./account";
import type { PlanRefusal } from "./ops";
import type { CloudState, CloudStore } from "./store";
import { format, L } from "./strings";

export function MigrationBanner({ store, state, strings }: { store: CloudStore; state: CloudState; strings: Strings }) {
  const { t } = strings;
  const count = migrationBanner(state);
  if (count === undefined) return null;
  return (
    <section className="cloud-migration" aria-label={format(t(L.migrationTitle), { count })}>
      <span className="cloud-migration-text">
        <strong className="cloud-migration-title">{format(t(L.migrationTitle), { count })}</strong>
        <span>{t(L.migrationBody)}</span>
      </span>
      <span className="cloud-item-actions">
        <button
          type="button"
          className="cloud-button cloud-migration-later"
          onClick={() => store.account.dismissMigration()}
        >
          {t(L.migrationLater)}
        </button>
        <button
          type="button"
          className="cloud-button primary cloud-migration-move"
          onClick={() => void store.account.startMigration()}
        >
          {t(L.migrationMove)}
        </button>
      </span>
    </section>
  );
}

/** The localized sentence of a plan refusal. */
export function refusalText(refusal: PlanRefusal, t: (key: string) => string): string {
  switch (refusal.kind) {
    case "plan_required":
      return t(L.planRequired);
    case "size_locked":
      return t(L.sizeLocked);
    case "quota_exceeded":
      return format(t(L.quotaExceeded), { used: refusal.used ?? "?", limit: refusal.limit ?? "?" });
  }
}

/**
 * A plan refusal with "See plans". The checkout needs a plan id: the error's `details.plan`, else
 * `CloudPlan.upgrade_plan` (`planRefusal`). When neither names one, the sentence shows alone.
 */
export function PlanNotice({
  store,
  refusal,
  strings,
  onDismiss,
}: {
  store: CloudStore;
  refusal: PlanRefusal;
  strings: Strings;
  onDismiss?: () => void;
}) {
  const { t } = strings;
  const plan = refusal.plan;
  return (
    <div className={`cloud-plan-notice kind-${refusal.kind}`} role="alert">
      <span className="cloud-plan-notice-text">{refusalText(refusal, t)}</span>
      <span className="cloud-item-actions">
        {plan && (
          <button
            type="button"
            className="cloud-button cloud-see-plans"
            onClick={() => void store.account.checkout(plan)}
          >
            {t(L.seePlans)}
          </button>
        )}
        {onDismiss && (
          <button type="button" className="cloud-link-button" onClick={onDismiss}>
            {t(L.dismissError)}
          </button>
        )}
      </span>
    </div>
  );
}
