// Two notices: the one-time banner for machines from cmux Cloud classic (contract 4: "Move them"
// runs `cloud.migration.start` as a native action, "Later" hides it for this page session), and a
// typed plan refusal (contract 1.5: `plan_required`, `quota_exceeded {limit, used}`, `size_locked`)
// as a localized sentence with "See plans", which runs `cloud.billing.checkout {plan}` natively.
import type { Strings } from "../shared/i18n";
import { migrationBanner } from "./account";
import { PLANS_URL, type PlanRefusal } from "./ops";
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
 * A plan refusal with "See plans", shown when a plan lifts the limit: the error's `details.plan`, else
 * `CloudPlan.upgrade_plan` (`planRefusal`); otherwise the sentence shows alone. "See plans" links the
 * public plans page ([PLANS_URL]) until billing lands; then it runs the checkout of that plan.
 */
export function PlanNotice({
  refusal,
  strings,
  onDismiss,
}: {
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
          // A plain link: the host opens it outside the page on the person's click (PageNavigation).
          <a className="cloud-button cloud-see-plans" href={PLANS_URL}>
            {t(L.seePlans)}
          </a>
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
