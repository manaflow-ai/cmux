import { Resend } from "resend";
import type Stripe from "stripe";

import { env } from "../../app/env";
import enMessages from "../../messages/en.json";
import jaMessages from "../../messages/ja.json";
import { isAscConfigured } from "../asc/client";
import { enrollTester } from "../asc/testflight";

export const DEFAULT_PRO_FROM_EMAIL = "pro@cmux.com";
export const PRO_REPLY_TO_EMAIL = "founders@manaflow.com";
export const PRO_TESTFLIGHT_SIGNUP_URL = "https://cmux.com/dashboard/testflight";

type ProWelcomeLocale = "en" | "ja";

type ProFulfillmentDependencies = {
  isAscConfigured: () => boolean;
  enrollTester: (
    email: string,
    firstName?: string,
    lastName?: string,
  ) => Promise<void>;
  sendEmail: (
    payload: ProWelcomeEmail,
    options: { idempotencyKey: string },
  ) => Promise<{ error: unknown | null }>;
  fromEmail: () => string;
};

const defaultDependencies: ProFulfillmentDependencies = {
  isAscConfigured,
  enrollTester,
  sendEmail: async (payload, options) => {
    const resend = new Resend(env.RESEND_API_KEY);
    return resend.emails.send(payload, options);
  },
  fromEmail: () => env.CMUX_PRO_FROM_EMAIL ?? DEFAULT_PRO_FROM_EMAIL,
};

export type ProWelcomeEmail = {
  from: string;
  to: string[];
  replyTo: string;
  subject: string;
  text: string;
  html: string;
  headers: Record<string, string>;
};

export async function fulfillProCheckout(
  input: {
    session: Stripe.Checkout.Session;
    stackUserId: string;
  },
  dependencies: ProFulfillmentDependencies = defaultDependencies,
): Promise<void> {
  const email = checkoutEmail(input.session);
  if (!email) {
    throw new Error("cmux Pro checkout is missing a customer email");
  }
  if (!dependencies.isAscConfigured()) {
    throw new Error("cmux Pro TestFlight enrollment is not configured");
  }

  const customerName = checkoutCustomerName(input.session);
  const { firstName, lastName } = splitCustomerName(customerName);
  await dependencies.enrollTester(email, firstName, lastName);

  const sessionRef = input.session.id;
  const payload = buildProWelcomeEmail({
    from: formatFromAddress(dependencies.fromEmail()),
    to: email,
    customerName,
    locale: checkoutLocale(input.session),
    sessionRef,
  });
  const { error } = await dependencies.sendEmail(payload, {
    idempotencyKey: `pro-welcome/${sessionRef}`,
  });
  if (error) {
    throw new Error(`cmux Pro welcome email failed: ${errorMessage(error)}`);
  }
}

export function buildProWelcomeEmail(input: {
  from: string;
  to: string;
  customerName?: string | null;
  locale: ProWelcomeLocale;
  sessionRef: string;
}): ProWelcomeEmail {
  const copy = input.locale === "ja"
    ? jaMessages.emails.proWelcome
    : enMessages.emails.proWelcome;
  const name = firstName(input.customerName) ?? copy.fallbackName;
  const greeting = copy.greeting.replace("{name}", name);
  const testflightLink = copy.testflightLink.replace(
    "{url}",
    PRO_TESTFLIGHT_SIGNUP_URL,
  );
  return {
    from: input.from,
    to: [input.to],
    replyTo: PRO_REPLY_TO_EMAIL,
    subject: copy.subject,
    text: [
      greeting,
      "",
      copy.thanks,
      "",
      copy.cloudStatus,
      "",
      copy.currentBenefit,
      "",
      testflightLink,
      "",
      copy.signoff,
    ].join("\n"),
    html: [
      `<p>${escapeHtml(greeting)}</p>`,
      `<p>${escapeHtml(copy.thanks)}</p>`,
      `<p>${escapeHtml(copy.cloudStatus)}</p>`,
      `<p>${escapeHtml(copy.currentBenefit)}</p>`,
      `<p><a href="${PRO_TESTFLIGHT_SIGNUP_URL}">${escapeHtml(copy.testflightLinkLabel)}</a></p>`,
      `<p>${escapeHtml(copy.signoff).replaceAll("\n", "<br>")}</p>`,
    ].join(""),
    headers: { "X-Entity-Ref-ID": `pro-welcome/${input.sessionRef}` },
  };
}

function checkoutEmail(session: Stripe.Checkout.Session): string | null {
  const email = session.customer_details?.email ?? expandedCustomer(session)?.email;
  const normalized = email?.trim().toLowerCase();
  return normalized || null;
}

function checkoutCustomerName(session: Stripe.Checkout.Session): string | null {
  const name = session.customer_details?.name ?? expandedCustomer(session)?.name;
  const normalized = name?.trim();
  return normalized || null;
}

function checkoutLocale(session: Stripe.Checkout.Session): ProWelcomeLocale {
  const sessionLocale = session.locale === "auto" ? null : session.locale;
  const preferredLocale = expandedCustomer(session)?.preferred_locales?.[0];
  const locale = sessionLocale ?? preferredLocale;
  return locale?.toLowerCase().startsWith("ja") ? "ja" : "en";
}

function expandedCustomer(session: Stripe.Checkout.Session): Stripe.Customer | null {
  const customer = session.customer;
  if (typeof customer !== "object" || customer === null) return null;
  if ("deleted" in customer && customer.deleted) return null;
  return customer as Stripe.Customer;
}

function splitCustomerName(name: string | null): {
  firstName?: string;
  lastName?: string;
} {
  const parts = name?.trim().split(/\s+/).filter(Boolean) ?? [];
  const first = parts.shift();
  const last = parts.join(" ");
  return {
    firstName: first || undefined,
    lastName: last || undefined,
  };
}

function firstName(name: string | null | undefined): string | null {
  return name?.trim().split(/\s+/)[0] || null;
}

function formatFromAddress(email: string): string {
  return `cmux Pro <${email}>`;
}

function escapeHtml(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function errorMessage(error: unknown): string {
  if (error instanceof Error) return error.message;
  if (
    error &&
    typeof error === "object" &&
    "message" in error &&
    typeof error.message === "string"
  ) {
    return error.message;
  }
  return String(error);
}
