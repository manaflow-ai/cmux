// Three notices: the team's spending cap (cmuxterm-hq#8205: near it, a pending pause, machines paused,
// or no starts; drawn from `cloud.plan.get`'s `spend_cap`), the one-time banner for machines from cmux
// Cloud classic (contract 4: "Move them" runs `cloud.migration.start` as a native action, "Later"
// hides it for this page session), and a typed plan refusal (contract 1.5: `plan_required`, `quota_exceeded {limit, used}`, `size_locked`)
// as a localized sentence with "See plans", which links the public plans page until billing lands.
import { Notice } from "../../ui/Notice";
import type { Strings } from "../shared/i18n";
import { migrationBanner } from "./account";
import { PLANS_URL, type PlanRefusal } from "./ops";
import { askLine, capBanner, capBannerText, spentLine, usd } from "./spendCap";
import type { CloudState, CloudStore } from "./store";
import { format, L } from "./strings";

/**
 * The team's spending cap across the top of the page, from `cloud.plan.get`'s `spend_cap`: near the cap (the
 * person can dismiss it for this page session), the 15-minute warning before running machines pause, the pause,
 * or no new starts. At the cap it stays until the cap is raised or resets. Drawn as the shared notice's warning.
 */
export function SpendCapBanner({
  state,
  strings,
  hiddenNear,
  onHideNear,
}: {
  state: CloudState;
  strings: Strings;
  /** The person dismissed the near-cap banner in this page session (kept by the page across views). */
  hiddenNear: boolean;
  onHideNear: () => void;
}) {
  const { t, language } = strings;
  const banner = capBanner(state.plan?.spend_cap);
  if (!banner || (banner.kind === "near" && hiddenNear)) return null;
  const { title, message } = capBannerText(banner, t, language);
  return (
    <Notice
      kind="warning"
      placement="banner"
      className={`cloud-spend-cap kind-${banner.kind}`}
      title={title}
      message={message}
      onDismiss={banner.kind === "near" ? onHideNear : undefined}
      dismissLabel={t(L.dismissError)}
    />
  );
}

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
export function refusalText(refusal: PlanRefusal, t: (key: string) => string, language = "en"): string {
  switch (refusal.kind) {
    case "plan_required":
      return t(L.planRequired);
    case "size_locked":
      return t(L.sizeLocked);
    case "quota_exceeded":
      return format(t(L.quotaExceeded), { used: refusal.used ?? "?", limit: refusal.limit ?? "?" });
    case "spend_cap":
      return [spentLine(refusal.spentUsd, refusal.capUsd, t, language), askLine(refusal.periodEnd, t, language)]
        .filter(Boolean)
        .join(" ");
    case "member_budget":
      return refusal.spentUsd !== undefined && refusal.capUsd !== undefined
        ? format(t(L.budgetSpent), { spent: usd(refusal.spentUsd, language), limit: usd(refusal.capUsd, language) })
        : t(L.capAskAdmin);
  }
}

/** A spend refusal's title (the line under it says what to do); the plan refusals are one sentence. */
export function refusalTitle(refusal: PlanRefusal, t: (key: string) => string): string | undefined {
  if (refusal.kind === "spend_cap") return t(L.capReached);
  if (refusal.kind === "member_budget") return t(L.budgetReached);
  return undefined;
}

/**
 * A plan refusal with "See plans", shown when a plan lifts the limit: the error's `details.plan`, else
 * `CloudPlan.upgrade_plan` (`planRefusal`); otherwise the sentence shows alone. "See plans" links the
 * public plans page ([PLANS_URL]) until billing lands; then it runs the checkout of that plan. Drawn as
 * the shared notice's warning (ui/Notice.tsx): it stays until the person dismisses it or the cause goes.
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
  const { t, language } = strings;
  return (
    <Notice
      kind="warning"
      className={`cloud-plan-notice kind-${refusal.kind}`}
      title={refusalTitle(refusal, t)}
      message={refusalText(refusal, t, language)}
      // A plain link: the host opens it outside the page on the person's click (PageNavigation).
      actions={refusal.plan ? [{ id: "see-plans", label: t(L.seePlans), href: PLANS_URL, primary: true }] : []}
      onDismiss={onDismiss}
      dismissLabel={t(L.dismissError)}
    />
  );
}
