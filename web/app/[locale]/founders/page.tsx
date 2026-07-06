import { getTranslations } from "next-intl/server";

import { buildAlternates } from "../../../i18n/seo";
import {
  resolveFoundersBilling,
  type FoundersBillingResolution,
  type FoundersStackUser,
  type FoundersSubscriptionSummary,
} from "../../../services/billing/founders";
import { isStripeBillingConfigured } from "../../../services/billing/stripe";
import { PrimaryLink, SecondaryLink } from "../../components/pricing-shared";
import { getStackServerApp, isStackConfigured } from "../../lib/stack";
import { localizedVaultPath, vaultSignInHref } from "../../lib/vault-auth";
import { SiteHeader } from "../components/site-header";

export const dynamic = "force-dynamic";

type PageProps = {
  params: Promise<{ locale: string }>;
  searchParams: Promise<{ billing?: string | string[] }>;
};

const ACCOUNT_SETTINGS_HREF = "/handler/account-settings";
const FOUNDERS_EMAIL = "founders@manaflow.ai";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "founders" });
  return {
    title: t("metaTitle"),
    description: t("metaDescription"),
    alternates: buildAlternates(locale, "/founders"),
  };
}

export default async function FoundersPage({ params, searchParams }: PageProps) {
  const { locale } = await params;
  const { billing } = await searchParams;
  const t = await getTranslations({ locale, namespace: "founders" });
  const billingFeedback = Array.isArray(billing) ? billing[0] : billing;

  let content;
  if (!isStackConfigured() || !isStripeBillingConfigured()) {
    content = <UnavailableState locale={locale} />;
  } else {
    const user = await getStackServerApp().getUser({ or: "return-null" });
    if (!user || user.isAnonymous) {
      content = <SignedOutState locale={locale} />;
    } else {
      const resolution = await resolveFoundersBilling(user);
      content = (
        <SignedInState
          locale={locale}
          resolution={resolution}
          user={user}
        />
      );
    }
  }

  return (
    <div className="min-h-screen">
      <SiteHeader />
      <main className="w-full max-w-2xl mx-auto px-6 py-16 sm:py-20">
        {billingFeedback === "error" ? (
          <div className="mb-6 border border-border p-3 text-sm text-muted">
            {t("errorBanner")}
          </div>
        ) : null}
        {content}
      </main>
    </div>
  );
}

async function SignedOutState({ locale }: { locale: string }) {
  const t = await getTranslations({ locale, namespace: "founders" });
  return (
    <section>
      <h1 className="text-2xl font-medium tracking-tight">{t("title")}</h1>
      <p className="mt-5 text-[15px] leading-relaxed text-muted">
        {t("signIn.lead")}
      </p>
      <p className="mt-3 text-sm leading-relaxed text-muted">
        {t("signIn.note")}
      </p>
      <div className="mt-7">
        <PrimaryLink href={vaultSignInHref(localizedVaultPath(locale, "/founders"))}>
          {t("signIn.cta")}
        </PrimaryLink>
      </div>
    </section>
  );
}

async function SignedInState({
  locale,
  resolution,
  user,
}: {
  locale: string;
  resolution: FoundersBillingResolution;
  user: FoundersStackUser;
}) {
  if (resolution.status === "email-unverified") {
    return <VerifyState locale={locale} user={user} />;
  }
  if (resolution.status === "no-subscription") {
    return <MissingState email={resolution.email} locale={locale} />;
  }
  return <ManageState locale={locale} resolution={resolution} />;
}

async function VerifyState({
  locale,
  user,
}: {
  locale: string;
  user: FoundersStackUser;
}) {
  const t = await getTranslations({ locale, namespace: "founders" });
  return (
    <section>
      <h1 className="text-2xl font-medium tracking-tight">{t("title")}</h1>
      {user.primaryEmail ? (
        <p className="mt-4 text-sm text-muted">
          {t("signedInAs", { email: user.primaryEmail })}
        </p>
      ) : null}
      <div className="mt-6 border border-border p-5">
        <p className="text-[15px] leading-relaxed">{t("verify.lead")}</p>
        <p className="mt-3 text-sm leading-relaxed text-muted">
          {t("verify.note")}
        </p>
        <div className="mt-6 flex flex-wrap gap-3">
          <PrimaryLink href={ACCOUNT_SETTINGS_HREF}>{t("verify.cta")}</PrimaryLink>
          <SecondaryLink href={switchAccountHref(locale)}>
            {t("verify.switchAccount")}
          </SecondaryLink>
        </div>
      </div>
    </section>
  );
}

async function MissingState({
  email,
  locale,
}: {
  email: string;
  locale: string;
}) {
  const t = await getTranslations({ locale, namespace: "founders" });
  return (
    <section>
      <h1 className="text-2xl font-medium tracking-tight">{t("missing.title")}</h1>
      <div className="mt-6 border border-border p-5">
        <p className="text-[15px] leading-relaxed">
          {t("missing.body", { email })}
        </p>
        <p className="mt-3 text-sm leading-relaxed text-muted">
          {t("missing.tip")}
        </p>
        <p className="mt-3 text-sm leading-relaxed text-muted">
          {t.rich("missing.contact", {
            email: (chunks) => (
              <a href={`mailto:${FOUNDERS_EMAIL}`} className={linkClassName}>
                {chunks}
              </a>
            ),
          })}
        </p>
        <div className="mt-6">
          <SecondaryLink href={switchAccountHref(locale)}>
            {t("missing.switchAccount")}
          </SecondaryLink>
        </div>
      </div>
    </section>
  );
}

async function ManageState({
  locale,
  resolution,
}: {
  locale: string;
  resolution: Extract<FoundersBillingResolution, { status: "ready" }>;
}) {
  const t = await getTranslations({ locale, namespace: "founders" });
  const formatter = new Intl.DateTimeFormat(locale, { dateStyle: "long" });
  return (
    <section>
      <h1 className="text-2xl font-medium tracking-tight">{t("title")}</h1>
      <p className="mt-4 text-sm text-muted">
        {t("signedInAs", { email: resolution.email })}
      </p>
      <p className="mt-5 text-[15px] leading-relaxed text-muted">
        {t("manage.lead")}
      </p>
      <div className="mt-7 space-y-4">
        {resolution.subscriptions.map((subscription) => (
          <SubscriptionCard
            formatter={formatter}
            key={subscription.id}
            locale={locale}
            subscription={subscription}
          />
        ))}
      </div>
      <div className="mt-7 flex flex-wrap gap-3">
        <PrimaryLink href="/api/founders/portal">{t("manage.cta")}</PrimaryLink>
        <SecondaryLink href={switchAccountHref(locale)}>
          {t("manage.switchAccount")}
        </SecondaryLink>
      </div>
      <p className="mt-6 text-sm leading-relaxed text-muted">
        {t.rich("manage.help", {
          email: (chunks) => (
            <a href={`mailto:${FOUNDERS_EMAIL}`} className={linkClassName}>
              {chunks}
            </a>
          ),
        })}
      </p>
    </section>
  );
}

async function SubscriptionCard({
  formatter,
  locale,
  subscription,
}: {
  formatter: Intl.DateTimeFormat;
  locale: string;
  subscription: FoundersSubscriptionSummary;
}) {
  const t = await getTranslations({ locale, namespace: "founders" });
  return (
    <article className="border border-border p-5">
      <h2 className="text-[15px] font-medium tracking-tight">
        {subscription.productName ?? t("manage.fallbackProductName")}
      </h2>
      <p className="mt-2 text-sm text-muted">
        {statusLabel(subscription.status, t)}
      </p>
      {subscription.currentPeriodEnd ? (
        <p className="mt-2 text-sm text-muted">
          {subscription.cancelAtPeriodEnd
            ? t("manage.endsOn", {
                date: formatter.format(subscription.currentPeriodEnd),
              })
            : t("manage.renewsOn", {
                date: formatter.format(subscription.currentPeriodEnd),
              })}
        </p>
      ) : null}
    </article>
  );
}

async function UnavailableState({ locale }: { locale: string }) {
  const t = await getTranslations({ locale, namespace: "founders" });
  return (
    <section>
      <h1 className="text-2xl font-medium tracking-tight">
        {t("unavailable.title")}
      </h1>
      <div className="mt-6 border border-border p-5">
        <p className="text-[15px] leading-relaxed text-muted">
          {t.rich("unavailable.body", {
            email: (chunks) => (
              <a href={`mailto:${FOUNDERS_EMAIL}`} className={linkClassName}>
                {chunks}
              </a>
            ),
          })}
        </p>
      </div>
    </section>
  );
}

function switchAccountHref(locale: string): string {
  return `/handler/sign-out-and-sign-in?after_auth_return_to=${encodeURIComponent(
    vaultSignInHref(localizedVaultPath(locale, "/founders")),
  )}`;
}

function statusLabel(
  status: string,
  t: Awaited<ReturnType<typeof getTranslations>>,
): string {
  switch (status) {
    case "active":
      return t("statuses.active");
    case "trialing":
      return t("statuses.trialing");
    case "past_due":
      return t("statuses.past_due");
    case "canceled":
      return t("statuses.canceled");
    case "unpaid":
      return t("statuses.unpaid");
    case "incomplete":
      return t("statuses.incomplete");
    case "incomplete_expired":
      return t("statuses.incomplete_expired");
    case "paused":
      return t("statuses.paused");
    default:
      return status;
  }
}

const linkClassName =
  "underline underline-offset-2 decoration-border hover:decoration-foreground transition-colors";
