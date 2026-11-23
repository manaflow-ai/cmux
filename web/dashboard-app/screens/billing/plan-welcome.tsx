"use client";

import { Link } from "@tanstack/react-router";
import { useTranslations } from "next-intl";
import { settingsButtonClass } from "@/dashboard-app/components/settings-ui/styles";
import { cloudIntroOfferFacts } from "@/services/billing/cloudIntroOffer";
import { CLOUD_TASTE_AWAKE_HOURS, CLOUD_TASTE_INCLUDED, CLOUD_TASTE_TERM_DAYS } from "@/services/billing/cloudTaste";
import { CLOUD_INTRO_KEEP_DAYS } from "@/services/billing/cloudIntro";
import {
  CLOUD_INTRO_PASS_NOT_NOW,
  type CloudIntroStatementNotice as CloudIntroStatementNoticeJson,
} from "@/services/billing/cloudIntroStatements";

/** The turn-off POST (services/billing/cloudIntroRenewRoute.ts); kept here so the client bundle does not pull in the route. */
const CLOUD_INTRO_RENEW_OFF_ACTION = "/api/billing/cloud-pass/renew";

export type WelcomePlan = "go" | "pro" | "max";

/** `?welcome=` after a personal checkout; anything else is no welcome. */
export function welcomePlan(value: unknown): WelcomePlan | null {
  return value === "go" || value === "pro" || value === "max" ? value : null;
}

/** Plan & billing after checkout: what unlocked and the first things to try. */
export function PlanWelcome({ plan }: { readonly plan: WelcomePlan }) {
  const t = useTranslations("dashboard.billing");
  const name = t(`picker.names.${plan}`);
  return (
    <section data-testid="plan-welcome" className="mb-3 border border-foreground p-3">
      <h2 className="text-sm font-medium">{t("welcome.title", { plan: name })}</h2>
      <p className="mt-1 text-xs text-muted">{t("welcome.body")}</p>
      <ul className="mt-2 space-y-1 text-xs text-muted">
        {(t.raw(`picker.features.${plan}`) as string[]).map((line) => <li key={line}>{line}</li>)}
      </ul>
      <div className="mt-3 flex flex-wrap gap-2">
        <Link to="/dashboard/testflight" className={settingsButtonClass("primary", "sm")}>{t("welcome.ios")}</Link>
        <Link to="/dashboard/teams/new" className={settingsButtonClass("secondary", "sm")}>{t("welcome.team")}</Link>
      </div>
    </section>
  );
}

/** Plan & billing after the $1 pass checkout (`?welcome=intro`). */
export function CloudIntroWelcome() {
  const t = useTranslations("dashboard.billing");
  const facts = cloudIntroOfferFacts();
  return (
    <section data-testid="cloud-intro-welcome" className="mb-3 border border-foreground p-3">
      <h2 className="text-sm font-medium">{t("welcome.introTitle")}</h2>
      <p className="mt-1 text-xs text-muted">
        {t("welcome.introBody", {
          days: facts.termDays,
          hours: facts.chiefHoursWeekly,
          minutes: facts.machineMinutesWeekly.toLocaleString("en-US"),
        })}
      </p>
    </section>
  );
}

/** Plan & billing after the free week is granted (`?welcome=taste`). */
export function CloudTasteWelcome() {
  const t = useTranslations("dashboard.billing");
  return (
    <section data-testid="cloud-taste-welcome" className="mb-3 border border-foreground p-3">
      <h2 className="text-sm font-medium">{t("welcome.tasteTitle")}</h2>
      <p className="mt-1 text-xs text-muted">
        {t("welcome.tasteBody", {
          days: CLOUD_TASTE_TERM_DAYS,
          hours: CLOUD_TASTE_AWAKE_HOURS,
          minutes: CLOUD_TASTE_INCLUDED.machineMinutes.toLocaleString("en-US"),
        })}
      </p>
    </section>
  );
}

/**
 * The latest $1 pass statement on Plan & billing: the same lines as the
 * email, built on the server. `?pass=not-now` (the statement's "Not now")
 * confirms what happens when the pass ends; the later Plus charge is turned
 * off with a form post, and `?pass=renew-off` / `renew-too-late` report it.
 */
export function CloudIntroStatementNotice({
  notice,
  pass,
}: {
  readonly notice: CloudIntroStatementNoticeJson;
  readonly pass?: string;
}) {
  const t = useTranslations("dashboard.billing");
  const notNow = pass === CLOUD_INTRO_PASS_NOT_NOW;
  return (
    <section data-testid="cloud-intro-statement" aria-label={t("passStatement.label")} className="mb-3 border border-foreground p-3">
      <h2 className="text-sm font-medium">{notice.title}</h2>
      <ul className="mt-1 space-y-1 text-xs text-muted">
        {notice.lines.map((line) => <li key={line}>{line}</li>)}
      </ul>
      {notice.turnOff ? (
        <form method="post" action={CLOUD_INTRO_RENEW_OFF_ACTION} className="mt-2">
          <button type="submit" data-testid="cloud-intro-statement-turn-off" className={settingsButtonClass("secondary", "sm")}>
            {notice.turnOff.label}
          </button>
        </form>
      ) : null}
      {pass === "renew-off" ? (
        <p data-testid="cloud-intro-statement-renew-off" className="mt-2 text-xs">{t("passStatement.turnedOff")}</p>
      ) : null}
      {pass === "renew-too-late" ? (
        <p data-testid="cloud-intro-statement-renew-too-late" className="mt-2 text-xs">{t("passStatement.tooLate")}</p>
      ) : null}
      {notNow ? (
        <div data-testid="cloud-intro-statement-not-now" className="mt-3 text-xs">
          <p className="font-medium">{t("passStatement.notNowTitle")}</p>
          <p className="mt-1 text-muted">{t("passStatement.notNowBody", { keepDays: CLOUD_INTRO_KEEP_DAYS })}</p>
        </div>
      ) : null}
      {notice.askTitle ? <p className="mt-3 text-xs font-medium">{notice.askTitle}</p> : null}
      {notice.choices.length > 0 ? (
        <div className="mt-2 flex flex-wrap gap-2">
          {notice.choices.map((choice) => (
            <a
              key={choice.key}
              data-testid={`cloud-intro-statement-${choice.key}`}
              href={choice.href}
              className={settingsButtonClass(choice.key === "plus" ? "primary" : "secondary", "sm")}
            >
              {choice.label}
            </a>
          ))}
        </div>
      ) : null}
      {notice.after && !notNow ? <p className="mt-2 text-xs text-muted">{notice.after}</p> : null}
    </section>
  );
}

/** A page a checkout returned to: one line, and the way to Plan & billing. */
export function PlanWelcomeBanner({ plan }: { readonly plan: WelcomePlan }) {
  const t = useTranslations("dashboard.billing");
  return (
    <p data-testid="plan-welcome" className="mb-3 border border-foreground p-3 text-xs">
      {t("welcome.banner", { plan: t(`picker.names.${plan}`) })}{" "}
      <Link to="/dashboard/billing" className="underline">{t("welcome.bannerLink")}</Link>
    </p>
  );
}
