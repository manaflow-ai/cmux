// Pure construction of the cmux Founder's Edition welcome email payload.
//
// Kept free of Stripe/Resend/env imports so it can be unit-tested directly
// (web/tests/founders-welcome-email.test.ts) without booting the webhook route
// or touching the network. The route handler (./route.ts) owns the I/O.

import englishMessages from "../../../../messages/en.json";
import { loadMessages } from "../../../../i18n/messages";
import type { Locale } from "../../../../i18n/routing";

// Default sender/recipients. Sender is overridable via env so the verified
// Resend domain can change without a code edit; the founders are always copied
// so both see exactly what the customer received.
export const DEFAULT_FROM_EMAIL = "austin@manaflow.ai";
export const FOUNDER_CC = ["austin@manaflow.ai", "lawrence@manaflow.ai"];
export const REPLY_TO = "austin@manaflow.ai";
export const EMAIL_SUBJECT = "cmux Founder's Edition";

// Custom header that defeats Gmail's subject-based conversation grouping.
// Gmail collapses messages that share a normalized subject among the same
// participants into one conversation, so a unique value per message is what
// keeps each send in its own thread. Resend forwards arbitrary headers via the
// `headers` field on emails.send. See foundersThreadRef for why it is keyed to
// the session id rather than a per-delivery random value.
const THREAD_REF_HEADER = "X-Entity-Ref-ID";

function firstName(fullName: string | null | undefined): string | null {
  const trimmed = (fullName ?? "").trim();
  return trimmed ? trimmed.split(/\s+/)[0] : null;
}

function buildBody(name: string): string {
  return [
    `Hi ${name}!`,
    "",
    "Thank you for being one of the first ever customers of cmux :)",
    "",
    "My number is +1(714) 699-0169 and Lawrence's number is +1(949) 302-0749. " +
      "Our emails are austin@manaflow.ai and lawrence@manaflow.ai. Feel free to " +
      "text me on iMessage or WhatsApp, or we can just continue talking here. " +
      "I've CC'd my cofounder as well.",
    "",
    "cmux iOS Beta is out for cmux Founder's Edition! If you have a different " +
      "TestFlight email, please reply to this email with the new email address. " +
      "Otherwise, we'll send it to the one on file.",
    "",
    "Best,",
    "Austin",
  ].join("\n");
}

// Stable-per-session, unique-per-subscription thread identifier.
//
// Every founder welcome shares the same subject + from + cc, so in austin@ and
// lawrence@'s inboxes (CC'd on every send) Gmail would collapse them all into a
// single conversation. Setting X-Entity-Ref-ID to this value gives each
// subscription its own thread.
//
// It is keyed to the Stripe checkout session id (the same id used for the
// Resend idempotency key) so that Stripe's at-least-once redelivery of the SAME
// session yields the SAME ref — the idempotent re-send stays in the single
// existing thread instead of spawning a duplicate — while a DIFFERENT
// subscription yields a DIFFERENT ref and therefore a new thread.
export function foundersThreadRef(sessionRef: string): string {
  return `founders-welcome/${sessionRef}`;
}

export type FoundersWelcomeEmail = {
  from: string;
  to: string[];
  cc: string[];
  replyTo: string;
  subject: string;
  text: string;
  headers: Record<string, string>;
};

type ProWelcomeCopy = {
  subject: string;
  fallbackName: string;
  greeting: string;
  thanks: string;
  cloudStatus: string;
  currentBenefit: string;
  testflightLink: string;
  signoff: string;
};

const ENGLISH_PRO_WELCOME_FALLBACK: ProWelcomeCopy = {
  subject: "Welcome to cmux Pro 🎉",
  fallbackName: "there",
  greeting: "Hey {name},",
  thanks:
    "Thanks for joining cmux Pro! We’re still putting the full Pro experience together, and cloud access is on the way.",
  cloudStatus:
    "When cloud access launches, we’ll add usage credits to your account based on how many months you’ve been subscribed.",
  currentBenefit:
    "In the meantime, your Pro benefit is early access to cmux on iOS. Sign up through the link below, and Apple will send your TestFlight invitation once you’re registered.",
  testflightLink: "Sign up for TestFlight: {url}",
  signoff: "Glad to have you here!\nThe cmux team",
};

const DEFAULT_PRO_WELCOME_COPY: ProWelcomeCopy = {
  ...ENGLISH_PRO_WELCOME_FALLBACK,
  ...readProWelcomeCopy(
    isRecord(englishMessages) && isRecord(englishMessages.emails)
      ? englishMessages.emails.proWelcome
      : undefined,
  ),
};

export const PRO_EMAIL_SUBJECT = DEFAULT_PRO_WELCOME_COPY.subject;

// Build the personal Founder's Edition payload. Per-subscription threading is
// carried by X-Entity-Ref-ID.
export function buildFoundersWelcomeEmail(params: {
  from: string;
  to: string;
  customerName: string | null | undefined;
  sessionRef: string;
  subject?: string;
}): FoundersWelcomeEmail {
  return buildPersonalWelcomeEmail({
    from: params.from,
    to: params.to,
    sessionRef: params.sessionRef,
    subject: params.subject ?? EMAIL_SUBJECT,
    text: buildBody(firstName(params.customerName) ?? "there"),
  });
}

function buildPersonalWelcomeEmail(params: {
  from: string;
  to: string;
  sessionRef: string;
  subject: string;
  text: string;
}): FoundersWelcomeEmail {
  return {
    from: params.from,
    to: [params.to],
    cc: FOUNDER_CC,
    replyTo: REPLY_TO,
    subject: params.subject,
    text: params.text,
    headers: { [THREAD_REF_HEADER]: foundersThreadRef(params.sessionRef) },
  };
}

/** Build a localized personal payload for a Pro checkout. */
export async function buildProWelcomeEmail(params: {
  from: string;
  to: string;
  customerName: string | null | undefined;
  sessionRef: string;
  locale?: Locale;
}): Promise<FoundersWelcomeEmail> {
  let localizedCopy: Partial<ProWelcomeCopy> = {};
  try {
    const catalog = await loadMessages(params.locale ?? "en");
    if (isRecord(catalog) && isRecord(catalog.emails)) {
      localizedCopy = readProWelcomeCopy(catalog.emails.proWelcome);
    }
  } catch {
    // Email delivery must continue with the English catalog when a locale is
    // unavailable or has incomplete data.
  }
  const copy = { ...DEFAULT_PRO_WELCOME_COPY, ...localizedCopy };
  const name = firstName(params.customerName) ?? copy.fallbackName;
  const greeting = copy.greeting.replace("{name}", name);
  const testflightLink = copy.testflightLink.replace(
    "{url}",
    "https://cmux.com/dashboard/testflight",
  );
  return buildPersonalWelcomeEmail({
    from: params.from,
    to: params.to,
    sessionRef: params.sessionRef,
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
  });
}

function readProWelcomeCopy(value: unknown): Partial<ProWelcomeCopy> {
  if (!isRecord(value)) return {};
  const copy: Partial<ProWelcomeCopy> = {};
  if (typeof value.subject === "string") copy.subject = value.subject;
  if (typeof value.fallbackName === "string") copy.fallbackName = value.fallbackName;
  if (typeof value.greeting === "string") copy.greeting = value.greeting;
  if (typeof value.thanks === "string") copy.thanks = value.thanks;
  if (typeof value.cloudStatus === "string") copy.cloudStatus = value.cloudStatus;
  if (typeof value.currentBenefit === "string") copy.currentBenefit = value.currentBenefit;
  if (typeof value.testflightLink === "string") copy.testflightLink = value.testflightLink;
  if (typeof value.signoff === "string") copy.signoff = value.signoff;
  return copy;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value && typeof value === "object" && !Array.isArray(value));
}
