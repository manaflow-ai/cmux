import type { Metadata } from "next";
import { headers } from "next/headers";
import { NextRequest } from "next/server";
import { redirect } from "next/navigation";
import type Stripe from "stripe";

import type { Locale } from "../../../i18n/routing";
import { locales, routing } from "../../../i18n/routing";
import {
  nativeCallbackHrefForScheme,
  trustedNativeCallbackScheme,
  validatedNativeCallbackScheme,
} from "../../lib/native-callback";
import { appPricingNativeReturnURL } from "../../lib/billing";
import { requestOrigin } from "../../lib/request-origin";
import {
  isCmuxCheckoutSession,
  isActiveStripeSubscriptionStatus,
  latestStripeSubscriptionForSession,
} from "../../../services/billing/purchase";
import { captureBillingError } from "../../../services/errors";
import {
  isStripeBillingConfigured,
  stripe,
} from "../../../services/billing/stripe";

type BillingSuccessMessages = {
  metaTitle: string;
  title: string;
  body: string;
  purchaseComplete: string;
  proLabel: string;
  dashboardLink: string;
  emailLabel: string;
  whatUnlockedTitle: string;
  openCmux: string;
  manageBilling: string;
  manageSignInMethods: string;
  features: Record<BillingSuccessFeatureKey, BillingSuccessFeatureMessage>;
};

type BillingSuccessFeatureKey =
  "cloudAgents" | "modelGateway" | "aiAccounts" | "iosApp";

type BillingSuccessFeatureMessage = {
  title: string;
  body: string;
  action: string;
};


export async function generateMetadata(): Promise<Metadata> {
  const { messages } = await billingSuccessMessages(await headers());
  return { title: messages.metaTitle };
}

export default async function BillingSuccessPage({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  if (!isStripeBillingConfigured()) redirect("/pricing?billing=unavailable");
  const params = await searchParams;
  const requestHeaders = await headers();
  const sessionId = firstParam(params.session_id);
  if (!sessionId) redirect("/pricing?billing=error");

  const request = requestFromHeaders(requestHeaders, "/billing/success");
  const requestedScheme = validatedNativeCallbackScheme(
    firstParam(params.cmux_scheme),
    request,
  );
  let session: Stripe.Checkout.Session;
  try {
    session = await stripe().checkout.sessions.retrieve(sessionId, {
      expand: ["subscription", "customer"],
    });
  } catch (error) {
    captureBillingError(error, {
      route: "/billing/success",
      hasSessionId: Boolean(sessionId),
    });
    redirect("/pricing?billing=error");
  }
  if (!isCmuxCheckoutSession(session, expandedSubscription(session))) {
    redirect("/pricing?billing=error");
  }
  const scheme =
    trustedNativeCallbackScheme(session.metadata?.nativeCallbackScheme) ??
    requestedScheme;
  const subscription = expandedSubscription(session);
  let recordedSubscription: Awaited<
    ReturnType<typeof latestStripeSubscriptionForSession>
  > = null;
  try {
    recordedSubscription = await latestStripeSubscriptionForSession(session);
  } catch (error) {
    captureBillingError(error, {
      route: "/billing/success",
      operation: "latestStripeSubscriptionForSession",
      hasSessionId: Boolean(sessionId),
    });
  }
  const active =
    (subscription && isActiveStripeSubscriptionStatus(subscription.status)) ||
    (recordedSubscription &&
      isActiveStripeSubscriptionStatus(recordedSubscription.status));
  if (!active) redirect("/pricing?welcome=pending");

  const email = purchaseEmail(session) ?? "";
  const { locale, messages } = await billingSuccessMessages(requestHeaders);
  const openCmuxHref = appPricingNativeReturnURL(
    new URL("/handler/after-sign-in", requestOrigin(request)),
    nativeCallbackHrefForScheme(scheme),
    sessionId,
  );
  const dashboardBillingHref = localizedDashboardPath(locale, "/dashboard/billing");
  const dashboardHref = localizedDashboardPath(locale, "/dashboard");
  const featureCards: readonly {
    key: BillingSuccessFeatureKey;
    href: string;
  }[] = [
    { key: "cloudAgents", href: openCmuxHref.toString() },
    { key: "modelGateway", href: localizedDashboardPath(locale, "/dashboard/coderouter") },
    { key: "aiAccounts", href: localizedDashboardPath(locale, "/dashboard/ai-accounts") },
    { key: "iosApp", href: localizedDashboardPath(locale, "/dashboard/testflight") },
  ];

  return (
    <main className="min-h-[calc(100vh-2.75rem)] bg-background px-3 py-6 text-foreground sm:px-6 sm:py-10" lang={locale}>
      <div className="mx-auto w-full max-w-5xl">
        <section className="border-b border-border pb-8">
          <div className="flex flex-wrap items-center justify-between gap-3 text-xs text-muted">
            <div className="flex items-center gap-2">
              <span className="grid size-5 place-items-center border border-foreground text-[11px]" aria-hidden="true">
                ✓
              </span>
              <span>{messages.purchaseComplete}</span>
            </div>
            <span className="font-mono tabular-nums">{messages.proLabel}</span>
          </div>
          <h1 className="mt-5 max-w-2xl text-2xl font-medium tracking-[-0.03em] sm:text-4xl">
            {messages.title}
          </h1>
          <p className="mt-3 max-w-2xl text-sm leading-6 text-muted sm:text-base">
            {messages.body.replace("{email}", email)}
          </p>
          <div className="mt-6 flex flex-wrap items-center gap-2">
            <a
              className="inline-flex min-h-10 items-center border border-foreground bg-foreground px-4 py-2 text-sm font-medium text-background transition-colors hover:bg-background hover:text-foreground focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground"
              href={openCmuxHref.toString()}
              target="_blank"
              rel="noreferrer"
            >
              {messages.openCmux}
              <span aria-hidden="true" className="ml-3">→</span>
            </a>
            <a
              className="inline-flex min-h-10 items-center border border-border px-4 py-2 text-sm font-medium hover:border-foreground focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground"
              href={dashboardBillingHref}
            >
              {messages.manageBilling}
            </a>
          </div>
        </section>

        <section className="border-b border-border py-8">
          <div className="flex flex-wrap items-baseline justify-between gap-3">
            <div>
              <h2 className="text-xl font-medium tracking-[-0.02em]">{messages.whatUnlockedTitle}</h2>
              <p className="mt-2 text-sm text-muted">{messages.emailLabel}: {email}</p>
            </div>
            <a className="text-sm text-muted underline decoration-border underline-offset-4 hover:text-foreground" href={dashboardHref}>
              {messages.dashboardLink}
            </a>
          </div>
          <div className="mt-6 grid border border-border md:grid-cols-2">
            {featureCards.map((card, index) => {
              const feature = messages.features[card.key];
              return (
                <article
                  key={card.key}
                  className={`group flex min-h-40 flex-col justify-between p-5 hover:bg-code-bg ${index < featureCards.length - 1 ? "border-b border-border md:border-b-0" : ""} ${index % 2 === 0 ? "md:border-r md:border-border" : ""}`}
                >
                  <div>
                    <h3 className="text-sm font-medium sm:text-base">{feature.title}</h3>
                    <p className="mt-3 max-w-md text-sm leading-6 text-muted">{feature.body}</p>
                  </div>
                  <a className="mt-5 inline-flex w-fit items-center text-sm font-medium underline decoration-border underline-offset-4 hover:decoration-foreground" href={card.href} target={card.key === "cloudAgents" ? "_blank" : undefined} rel={card.key === "cloudAgents" ? "noreferrer" : undefined}>
                    {feature.action}
                    <span aria-hidden="true" className="ml-2">→</span>
                  </a>
                </article>
              );
            })}
          </div>
        </section>

        <footer className="flex flex-wrap gap-x-6 gap-y-2 pt-5 text-sm text-muted">
          {/* The handler owns a full-document auth-settings transition. */}
          {/* eslint-disable-next-line @next/next/no-html-link-for-pages */}
          <a className="underline decoration-border underline-offset-4 hover:text-foreground" href="/handler/account-settings">
            {messages.manageSignInMethods}
          </a>
          <a className="underline decoration-border underline-offset-4 hover:text-foreground" href={dashboardBillingHref}>
            {messages.manageBilling}
          </a>
        </footer>
      </div>
    </main>
  );
}

function localizedDashboardPath(locale: Locale, path: string): string {
  return locale === routing.defaultLocale ? path : `/${locale}${path}`;
}

async function billingSuccessMessages(
  headersList: Headers,
): Promise<{ locale: Locale; messages: BillingSuccessMessages }> {
  const locale = preferredLocale(headersList);
  const messages = (await import(`../../../messages/${locale}.json`))
    .default as {
    billingSuccess?: BillingSuccessMessages;
  };
  if (messages.billingSuccess) {
    return { locale, messages: messages.billingSuccess };
  }
  // Only en and ja carry billingSuccess copy today. A buyer whose browser
  // resolves to any other locale must still see their post-purchase page
  // (this is the screen shown right after paying), so fall back to the
  // English copy rather than throwing a 500.
  const fallback = (await import("../../../messages/en.json")).default as {
    billingSuccess?: BillingSuccessMessages;
  };
  if (!fallback.billingSuccess) {
    throw new Error("Missing billingSuccess messages for the default locale");
  }
  return { locale: routing.defaultLocale, messages: fallback.billingSuccess };
}

function preferredLocale(headersList: Headers): Locale {
  const accepted = headersList.get("accept-language") ?? "";
  const requested = accepted
    .split(",")
    .map((part) => part.split(";")[0]?.trim())
    .filter(Boolean);
  for (const language of requested) {
    const exact = locales.find(
      (locale) => locale.toLowerCase() === language.toLowerCase(),
    );
    if (exact) return exact;
    const base = language.split("-")[0]?.toLowerCase();
    const baseMatch = locales.find(
      (locale) => locale.toLowerCase().split("-")[0] === base,
    );
    if (baseMatch) return baseMatch;
  }
  return routing.defaultLocale;
}

function requestFromHeaders(
  headersList: Headers,
  pathname: string,
): NextRequest {
  const host =
    headersList.get("x-forwarded-host") ??
    headersList.get("host") ??
    "cmux.com";
  const proto =
    headersList.get("x-forwarded-proto") ??
    (host.startsWith("localhost") ? "http" : "https");
  return new NextRequest(`${proto}://${host}${pathname}`, {
    headers: headersList,
  });
}

function expandedSubscription(
  session: Stripe.Checkout.Session,
): Stripe.Subscription | null {
  return typeof session.subscription === "object" &&
    session.subscription !== null
    ? session.subscription
    : null;
}

function purchaseEmail(session: Stripe.Checkout.Session): string | null {
  return session.customer_details?.email ?? null;
}

function firstParam(value: string | string[] | undefined): string | null {
  if (Array.isArray(value)) return value[0] ?? null;
  return value ?? null;
}
