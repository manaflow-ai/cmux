// The composer ring's plan usage popover (ComposerPickers ContextRing, when `agentPane.composerRing`
// is "planUsage"): the account's 5-hour and weekly limits with their reset times, and Codex's
// credits, after Claude desktop's "Plan usage limits" card and Codex's ring popover (Leo,
// 2026-11-04: "i guess we can turn that into a 5h/weekly usage type thing instead as well for some
// people"). It reads only what the harness reported (acpmux `usageLimits`); a window it did not
// report is not drawn, and nothing reported says so, never a 0%. Layouts: experiment
// `plan-usage-look` (planUsageLook.experiment.ts); the shipped one is `claude-bars`.
import { experimentArm } from "../../experiments/experiment";
import { useT } from "./i18n";
import type { AcpmuxUsageLimits } from "./model";
import { planUsageLook } from "./planUsageLook.experiment";
import { nativeExternalUrl } from "./session-info/native/links";
import { planCreditsLabel, planName, planPercent, planResetLabel, planUsageUrl, planWindowName } from "./usageLimits";
import "./planUsageCard.css";

export type PlanUsageLook = "claude-bars" | "codex-rows" | "compact";

export function PlanUsageCardBody({
  limits,
  family,
  look,
  now,
  locale,
  onOpenUrl,
}: {
  /// acpmux's `usageLimits` (usageLimitsOf); unset when the harness reported none.
  limits?: AcpmuxUsageLimits;
  /// The chat's harness family (`claude`, `codex`), which names the account's usage page.
  family?: string;
  /// The layout; the experiment's arm when unset.
  look?: PlanUsageLook;
  /// The clock the reset times read (the gallery pins it).
  now?: () => number;
  locale?: string;
  /// Opens the usage page; cmux's browser when unset.
  onOpenUrl?(url: string): void;
}) {
  const t = useT();
  const layout = look ?? experimentArm(planUsageLook);
  const at = now?.() ?? Date.now();
  const plan = planName(limits?.plan);
  const credits = planCreditsLabel(limits?.credits, t, locale);
  const url = limits ? planUsageUrl(family) : undefined;
  const open = () => {
    if (url) nativeExternalUrl(onOpenUrl)(url);
  };
  if (!limits) {
    return (
      <div className="acpmux-plan-usage" data-look={layout}>
        <div className="acpmux-plan-usage-title">{t("planUsage.title")}</div>
        <div className="acpmux-plan-usage-none">{t("planUsage.none")}</div>
      </div>
    );
  }
  if (layout === "codex-rows") {
    return (
      <div className="acpmux-plan-usage" data-look={layout}>
        {plan && <div className="acpmux-plan-usage-title">{t("planUsage.source", { plan })}</div>}
        <ul className="acpmux-plan-usage-rows">
          {limits.windows.map((limit) => (
            <li key={limit.id} className="acpmux-plan-usage-row">
              <span className="acpmux-plan-usage-name">{planWindowName(limit, t)}</span>
              <span className="acpmux-plan-usage-value">
                {t("planUsage.percentLeft", { percent: 100 - planPercent(limit.usedPercent) })}
              </span>
            </li>
          ))}
          {credits && (
            <li className="acpmux-plan-usage-row">
              <span className="acpmux-plan-usage-name">{t("planUsage.credits")}</span>
              <span className="acpmux-plan-usage-value">{credits}</span>
            </li>
          )}
        </ul>
        {url && (
          <button type="button" className="acpmux-plan-usage-link acpmux-plan-usage-foot" onClick={open}>
            {t("planUsage.manage")}
          </button>
        )}
      </div>
    );
  }
  return (
    <div className="acpmux-plan-usage" data-look={layout}>
      <div className="acpmux-plan-usage-head">
        <span className="acpmux-plan-usage-title">
          {plan ? t("planUsage.titlePlan", { plan }) : t("planUsage.title")}
        </span>
        {url && (
          <button type="button" className="acpmux-plan-usage-link" onClick={open}>
            {t("planUsage.seeAll")}
            <svg
              width={12}
              height={12}
              viewBox="0 0 16 16"
              fill="none"
              stroke="currentColor"
              strokeWidth={1.5}
              strokeLinecap="round"
              strokeLinejoin="round"
              aria-hidden="true"
              focusable="false"
            >
              <path d="M3 8h10M9 4l4 4-4 4" />
            </svg>
          </button>
        )}
      </div>
      <ul className="acpmux-plan-usage-rows">
        {limits.windows.map((limit) => {
          const name = planWindowName(limit, t);
          const reset = planResetLabel(limit, t, at, locale);
          const percent = t("planUsage.percentUsed", { percent: planPercent(limit.usedPercent) });
          return (
            <li key={limit.id} className="acpmux-plan-usage-window">
              <div className="acpmux-plan-usage-row">
                <span className="acpmux-plan-usage-name">{name}</span>
                {layout === "compact" && (
                  <progress className="acpmux-plan-usage-bar" aria-label={name} value={limit.usedPercent} max={100} />
                )}
                {layout !== "compact" && reset && <span className="acpmux-plan-usage-reset">{reset}</span>}
                <span className="acpmux-plan-usage-value">{percent}</span>
              </div>
              {layout === "compact" ? (
                reset && <div className="acpmux-plan-usage-reset">{reset}</div>
              ) : (
                <progress className="acpmux-plan-usage-bar" aria-label={name} value={limit.usedPercent} max={100} />
              )}
            </li>
          );
        })}
        {credits && (
          <li className="acpmux-plan-usage-window">
            <div className="acpmux-plan-usage-row">
              <span className="acpmux-plan-usage-name">{t("planUsage.credits")}</span>
              <span className="acpmux-plan-usage-value">{credits}</span>
            </div>
          </li>
        )}
      </ul>
    </div>
  );
}
