import type { Metadata } from "next";
import { headers } from "next/headers";
import { NextRequest } from "next/server";
import { redirect } from "next/navigation";
import type Stripe from "stripe";

import type { Locale } from "../../../i18n/routing";
import { locales, routing } from "../../../i18n/routing";
import {
  nativeCallbackHrefForScheme,
  validatedNativeCallbackScheme,
} from "../../lib/native-callback";
import {
  isActiveStripeSubscriptionStatus,
  latestStripeSubscriptionForSession,
} from "../../../services/billing/purchase";
import { captureBillingError } from "../../../services/errors";
import { isStripeBillingConfigured, stripe } from "../../../services/billing/stripe";

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
  | "cloudAgents"
  | "modelGateway"
  | "aiAccounts"
  | "iosApp";

type BillingSuccessFeatureMessage = {
  title: string;
  body: string;
  action: string;
};

export const dynamic = "force-dynamic";

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
  const scheme = validatedNativeCallbackScheme(firstParam(params.cmux_scheme), request);
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
  const subscription = expandedSubscription(session);
  let recordedSubscription: Awaited<ReturnType<typeof latestStripeSubscriptionForSession>> = null;
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
    (recordedSubscription && isActiveStripeSubscriptionStatus(recordedSubscription.status));
  if (!active) redirect("/pricing?welcome=pending");

  const email = purchaseEmail(session) ?? "";
  const { locale, messages } = await billingSuccessMessages(requestHeaders);
  const openCmuxHref = new URL("/handler/after-sign-in", request.nextUrl.origin);
  openCmuxHref.searchParams.set("native_app_return_to", nativeCallbackHrefForScheme(scheme));
  const featureCards: readonly {
    key: BillingSuccessFeatureKey;
    href: string;
  }[] = [
    { key: "cloudAgents", href: openCmuxHref.toString() },
    { key: "modelGateway", href: "/dashboard/subrouter" },
    { key: "aiAccounts", href: "/dashboard/ai-accounts" },
    { key: "iosApp", href: "/dashboard/testflight" },
  ];

  return (
    <main className="min-h-screen bg-[#fafafa] px-4 py-10 text-[#171717] sm:px-6 sm:py-16">
      <div className="mx-auto max-w-5xl" lang={locale}>
        <section className="border-b border-black/10 pb-8">
          <p className="mb-3 text-sm font-medium text-[#5f6368]">{messages.emailLabel}</p>
          <p className="mb-8 break-words text-base">{email}</p>
          <h1 className="text-3xl font-medium tracking-tight">{messages.title}</h1>
          <p className="mt-4 max-w-2xl text-base leading-7 text-[#4b5563]">
            {messages.body.replace("{email}", email)}
          </p>
          <a
            className="mt-8 inline-flex rounded-md bg-[#171717] px-4 py-2 text-sm font-medium text-white"
            href={openCmuxHref.toString()}
          >
            {messages.openCmux}
          </a>
        </section>

        <section className="py-8">
          <h2 className="text-xl font-medium tracking-tight">{messages.whatUnlockedTitle}</h2>
          <div className="mt-5 grid gap-4 md:grid-cols-2">
            {featureCards.map((card) => {
              const feature = messages.features[card.key];
              return (
                <article
                  key={card.key}
                  className="flex min-h-48 flex-col justify-between rounded-lg border border-black/10 bg-white p-5 shadow-sm"
                >
                  <div>
                    <h3 className="text-base font-medium">{feature.title}</h3>
                    <p className="mt-3 text-sm leading-6 text-[#4b5563]">{feature.body}</p>
                  </div>
                  <a
                    className="mt-5 inline-flex w-fit rounded-md bg-[#171717] px-3 py-2 text-sm font-medium text-white"
                    href={card.href}
                  >
                    {feature.action}
                  </a>
                </article>
              );
            })}
          </div>
        </section>

        <div className="flex flex-wrap gap-3 border-t border-black/10 pt-6">
          <a
            className="inline-flex rounded-md border border-black/15 px-4 py-2 text-sm font-medium text-[#171717]"
            href="/api/billing/portal"
          >
            {messages.manageBilling}
          </a>
          <a
            className="inline-flex rounded-md border border-black/15 px-4 py-2 text-sm font-medium text-[#171717]"
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
  const messages = (await import(`../../../messages/${locale}.json`)).default as {
    billingSuccess?: BillingSuccessMessages;
  };
  if (!messages.billingSuccess) {
    throw new Error(`Missing billingSuccess messages for locale ${locale}`);
  }
  return { locale, messages: messages.billingSuccess };
}

function preferredLocale(headersList: Headers): Locale {
  const accepted = headersList.get("accept-language") ?? "";
  const requested = accepted
    .split(",")
    .map((part) => part.split(";")[0]?.trim())
    .filter(Boolean);
  for (const language of requested) {
    const exact = locales.find((locale) => locale.toLowerCase() === language.toLowerCase());
    if (exact) return exact;
    const base = language.split("-")[0]?.toLowerCase();
    const baseMatch = locales.find((locale) => locale.toLowerCase().split("-")[0] === base);
    if (baseMatch) return baseMatch;
  }
  return routing.defaultLocale;
}

function requestFromHeaders(headersList: Headers, pathname: string): NextRequest {
  const host = headersList.get("x-forwarded-host") ?? headersList.get("host") ?? "cmux.com";
  const proto = headersList.get("x-forwarded-proto") ?? (host.startsWith("localhost") ? "http" : "https");
  return new NextRequest(`${proto}://${host}${pathname}`, { headers: headersList });
}

function expandedSubscription(session: Stripe.Checkout.Session): Stripe.Subscription | null {
  return typeof session.subscription === "object" && session.subscription !== null
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
