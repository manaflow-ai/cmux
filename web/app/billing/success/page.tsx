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
  if (!isCmuxCheckoutSession(session)) {
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
    new URL("/handler/after-sign-in", request.nextUrl.origin),
    nativeCallbackHrefForScheme(scheme),
    sessionId,
  );
  const featureCards: readonly {
    key: BillingSuccessFeatureKey;
    href: string;
  }[] = [
    { key: "cloudAgents", href: openCmuxHref.toString() },
    { key: "modelGateway", href: "/dashboard/coderouter" },
    { key: "aiAccounts", href: "/dashboard/ai-accounts" },
    { key: "iosApp", href: "/dashboard/testflight" },
  ];

  return (
    <main className="min-h-screen bg-[#f4f0e7] px-4 py-8 text-[#241f1a] sm:px-6 sm:py-14">
      <div className="mx-auto max-w-4xl" lang={locale}>
        <section className="border border-[#d6ccbc] bg-[#fffdf8]">
          <div className="grid border-b border-[#d6ccbc] sm:grid-cols-[1fr_auto]">
            <div className="p-6 sm:p-10">
              <div className="mb-8 flex items-center gap-3 text-sm font-medium text-[#7b5839]">
                <span className="grid size-7 place-items-center bg-[#e8a15b] text-base text-[#241f1a]">
                  ✓
                </span>
                <span>{messages.emailLabel}</span>
              </div>
              <h1 className="max-w-2xl text-3xl font-medium tracking-[-0.035em] sm:text-4xl">
                {messages.title}
              </h1>
              <p className="mt-4 max-w-2xl text-base leading-7 text-[#655c52]">
                {messages.body.replace("{email}", email)}
              </p>
              <a
                className="mt-8 inline-flex min-h-11 items-center bg-[#241f1a] px-5 py-2 text-sm font-medium text-[#fffaf1] transition-colors hover:bg-[#47382b]"
                href={openCmuxHref.toString()}
              >
                {messages.openCmux}
                <span aria-hidden="true" className="ml-3">
                  →
                </span>
              </a>
            </div>
            <div className="border-t border-[#d6ccbc] bg-[#f9e9d2] p-6 sm:w-64 sm:border-l sm:border-t-0 sm:p-8">
              <p className="text-xs font-medium uppercase tracking-[0.14em] text-[#8b6848]">
                {messages.emailLabel}
              </p>
              <p className="mt-3 break-words text-sm leading-6">{email}</p>
              <div className="mt-8 h-1 w-12 bg-[#e2813f]" />
            </div>
          </div>

          <div className="p-6 sm:p-10">
            <div className="flex items-end justify-between gap-6">
              <h2 className="text-xl font-medium tracking-tight">
                {messages.whatUnlockedTitle}
              </h2>
              <span className="hidden text-xs uppercase tracking-[0.14em] text-[#8b8176] sm:block">
                Pro
              </span>
            </div>
            <div className="mt-6 grid border-l border-t border-[#d6ccbc] md:grid-cols-2">
              {featureCards.map((card) => {
                const feature = messages.features[card.key];
                return (
                  <article
                    key={card.key}
                    className="group flex min-h-44 flex-col justify-between border-b border-r border-[#d6ccbc] bg-[#fffdf8] p-5 transition-colors hover:bg-[#fbf3e7]"
                  >
                    <div>
                      <h3 className="text-base font-medium">{feature.title}</h3>
                      <p className="mt-3 text-sm leading-6 text-[#655c52]">
                        {feature.body}
                      </p>
                    </div>
                    <a
                      className="mt-5 inline-flex w-fit items-center border-b border-[#8b6848] pb-1 text-sm font-medium text-[#6e4a2d]"
                      href={card.href}
                    >
                      {feature.action}
                      <span
                        aria-hidden="true"
                        className="ml-2 transition-transform group-hover:translate-x-0.5"
                      >
                        →
                      </span>
                    </a>
                  </article>
                );
              })}
            </div>
          </div>
        </section>

        <div className="flex flex-wrap gap-x-6 gap-y-3 border-x border-b border-[#d6ccbc] bg-[#ebe4d8] px-6 py-4 sm:px-10">
          <a
            className="inline-flex py-1 text-sm font-medium text-[#655c52] underline decoration-[#b7a895] underline-offset-4 hover:text-[#241f1a]"
            href="/api/billing/portal"
          >
            {messages.manageBilling}
          </a>
          <a
            className="inline-flex py-1 text-sm font-medium text-[#655c52] underline decoration-[#b7a895] underline-offset-4 hover:text-[#241f1a]"
            href="/handler/account-settings"
          >
            {messages.manageSignInMethods}
          </a>
        </div>
      </div>
    </main>
  );
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
