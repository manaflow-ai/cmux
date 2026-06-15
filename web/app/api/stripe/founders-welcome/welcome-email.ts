// Pure construction of the cmux Founder's Edition welcome email payload.
//
// Kept free of Stripe/Resend/env imports so it can be unit-tested directly
// (web/tests/founders-welcome-email.test.ts) without booting the webhook route
// or touching the network. The route handler (./route.ts) owns the I/O.

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

function firstName(fullName: string | null | undefined): string {
  const trimmed = (fullName ?? "").trim();
  if (!trimmed) {
    return "there";
  }
  return trimmed.split(/\s+/)[0];
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

// Build the Resend payload for a founder welcome. The customer-facing subject
// stays clean and constant across subscriptions; per-subscription threading is
// carried entirely by the X-Entity-Ref-ID header so the recipient sees no
// thread-key noise in the subject line.
export function buildFoundersWelcomeEmail(params: {
  from: string;
  to: string;
  customerName: string | null | undefined;
  sessionRef: string;
}): FoundersWelcomeEmail {
  return {
    from: params.from,
    to: [params.to],
    cc: FOUNDER_CC,
    replyTo: REPLY_TO,
    subject: EMAIL_SUBJECT,
    text: buildBody(firstName(params.customerName)),
    headers: { [THREAD_REF_HEADER]: foundersThreadRef(params.sessionRef) },
  };
}
