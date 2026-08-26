// Contact identity and name handling shared by every newsletter code path
// (audience sync script, Stripe webhook hook, tests).
//
// Kept free of network/env imports so the reconciliation rules can be
// unit-tested directly (web/tests/newsletter-reconcile.test.ts).

// A contact as we want it to exist in a Resend audience. `email` is always
// normalized (see normalizeEmail). Names are optional; absence means the
// source had no usable display name, and templates fall back via the Resend
// merge-tag default ({{{FIRST_NAME|there}}}) instead of storing a fake name.
export type NewsletterContact = {
  email: string;
  // Stable Stack identity used to preserve suppression when a user changes
  // their primary email. Stripe-only contacts intentionally omit this.
  stackUserId?: string;
  firstName?: string;
  lastName?: string;
  // Which sources claimed this contact; used for logging/diagnostics only.
  sources: NewsletterSource[];
};

export type NewsletterSource = "stack" | "stripe";

export const STACK_USER_ID_PROPERTY = "cmux_stack_user_id";
export const PREVIOUS_EMAILS_PROPERTY = "cmux_previous_emails";

// Deliberately loose shape check: one local part, one @, a dot-bearing
// domain. The sources (Stack, Stripe) have already validated deliverability;
// this gate only rejects values malformed enough to make Resend's create
// endpoint error mid-sync.
const EMAIL_SHAPE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

// Email addresses are compared case-insensitively across every source and
// against Resend. Lowercasing the whole address is safe for deduplication:
// RFC 5321 technically allows case-sensitive local parts, but no mainstream
// provider distinguishes them and Resend itself matches contacts
// case-insensitively.
export function normalizeEmail(raw: string | null | undefined): string | null {
  const trimmed = (raw ?? "").trim().toLowerCase();
  if (!EMAIL_SHAPE.test(trimmed)) {
    return null;
  }
  return trimmed;
}

// Split a free-form display name into Resend's first/last fields. The first
// whitespace-separated token becomes the first name and the remainder the
// last name, mirroring the firstName() heuristic in the founders welcome
// email. Empty input yields no name rather than empty strings so we never
// write "" into Resend (which would render as "Hi ," in a broadcast).
export function splitDisplayName(raw: string | null | undefined): {
  firstName?: string;
  lastName?: string;
} {
  const trimmed = (raw ?? "").trim();
  if (!trimmed) {
    return {};
  }
  const parts = trimmed.split(/\s+/);
  const firstName = parts[0];
  const lastName = parts.slice(1).join(" ");
  return lastName ? { firstName, lastName } : { firstName };
}

// Name-completeness score used when the same email appears in multiple
// sources with different name data.
export function nameScore(contact: {
  firstName?: string;
  lastName?: string;
}): number {
  let score = 0;
  if (contact.firstName) score += 1;
  if (contact.lastName) score += 1;
  return score;
}

// Merge contacts from multiple sources into one deduplicated list keyed by
// normalized email.
//
// Name precedence when the same person appears in several sources:
//   1. The candidate with more name parts (first+last beats first-only beats
//      none) wins, regardless of source order.
//   2. On a tie, the earlier-listed source wins. Callers list Stack Auth
//      before Stripe because the Stack display name is a profile the user
//      maintains themselves, while the Stripe name is whatever the card form
//      captured at purchase time.
export function mergeContactSources(
  sourceLists: NewsletterContact[][],
): NewsletterContact[] {
  const byEmail = new Map<string, NewsletterContact>();
  for (const list of sourceLists) {
    for (const contact of list) {
      // Keep the normalization invariant at this shared merge boundary too.
      // A future adapter must not create duplicate contacts solely because it
      // preserved email casing or surrounding whitespace.
      const email = normalizeEmail(contact.email);
      if (!email) {
        continue;
      }
      const existing = byEmail.get(email);
      if (!existing) {
        byEmail.set(email, {
          ...contact,
          email,
          sources: [...contact.sources],
        });
        continue;
      }
      for (const source of contact.sources) {
        if (!existing.sources.includes(source)) {
          existing.sources.push(source);
        }
      }
      if (nameScore(contact) > nameScore(existing)) {
        existing.firstName = contact.firstName;
        existing.lastName = contact.lastName;
      }
    }
  }
  return [...byEmail.values()];
}
