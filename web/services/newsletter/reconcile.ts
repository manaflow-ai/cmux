// Pure reconciliation: desired contacts (from Stack/Stripe) + existing Resend
// state (global contacts + one segment's membership) -> minimal set of safe
// mutations for that segment.
//
// Resend's data model: contacts are global per account, segments are
// targeting groups, and subscription state lives on the contact (global
// `unsubscribed`) and on per-topic preferences. Segment membership never
// changes subscription state.
//
// Safety invariants, enforced here and covered by
// web/tests/newsletter-reconcile.test.ts:
//   - Subscription state is a one-way door. A contact with global
//     unsubscribed=true gets no writes of any kind (no create, no segment
//     add, no name backfill), and no plan entry ever carries an
//     `unsubscribed` field or a topic preference, so a sync can never flip
//     anyone back to subscribed globally or per topic.
//   - Updates only backfill missing name fields. A name someone edited in
//     Resend (or that a previous sync wrote) is never overwritten, which also
//     makes re-running the sync a no-op.
//   - Contacts present in Resend but absent from the sources are left alone.
//     The sync only adds; it never removes contacts or segment memberships.

import type { NewsletterContact } from "./contacts";

// Existing global contact state read from Resend before any write is planned.
export type ExistingContact = {
  id: string;
  email: string;
  firstName?: string;
  lastName?: string;
  unsubscribed: boolean;
};

// Create a new global contact, placed directly into the target segment.
export type ContactCreate = {
  email: string;
  firstName?: string;
  lastName?: string;
};

// Add an existing, still-subscribed contact to the target segment.
export type SegmentAdd = {
  contactId: string;
  email: string;
};

// Fill in missing name fields on an existing, still-subscribed contact.
// Note: names live on the global contact, so a backfill planned while
// syncing one segment is visible account-wide; it still never overwrites a
// non-empty name.
export type ContactNameBackfill = {
  contactId: string;
  email: string;
  firstName?: string;
  lastName?: string;
};

export type SegmentPlan = {
  toCreate: ContactCreate[];
  toAddToSegment: SegmentAdd[];
  toBackfillName: ContactNameBackfill[];
  alreadyPresent: number;
  skippedUnsubscribed: number;
};

export function planSegmentSync(options: {
  desired: NewsletterContact[];
  existingContacts: ExistingContact[];
  segmentMemberEmails: ReadonlySet<string>;
}): SegmentPlan {
  const existingByEmail = new Map<string, ExistingContact>();
  for (const contact of options.existingContacts) {
    existingByEmail.set(contact.email.trim().toLowerCase(), contact);
  }
  const memberEmails = new Set(
    [...options.segmentMemberEmails].map((email) =>
      email.trim().toLowerCase(),
    ),
  );

  const plan: SegmentPlan = {
    toCreate: [],
    toAddToSegment: [],
    toBackfillName: [],
    alreadyPresent: 0,
    skippedUnsubscribed: 0,
  };

  for (const contact of options.desired) {
    // Desired emails come pre-normalized from the sources, but enforce the
    // invariant at the keying site too so a future source cannot silently
    // break case-insensitive matching.
    const desiredEmail = contact.email.trim().toLowerCase();
    const current = existingByEmail.get(desiredEmail);
    if (!current) {
      plan.toCreate.push({
        email: desiredEmail,
        ...(contact.firstName ? { firstName: contact.firstName } : {}),
        ...(contact.lastName ? { lastName: contact.lastName } : {}),
      });
      continue;
    }
    if (current.unsubscribed) {
      plan.skippedUnsubscribed += 1;
      continue;
    }
    const inSegment = memberEmails.has(desiredEmail);
    if (!inSegment) {
      plan.toAddToSegment.push({
        contactId: current.id,
        email: desiredEmail,
      });
    }
    const backfill: ContactNameBackfill = {
      contactId: current.id,
      email: desiredEmail,
    };
    let needsBackfill = false;
    if (!current.firstName && contact.firstName) {
      backfill.firstName = contact.firstName;
      needsBackfill = true;
    }
    if (!current.lastName && contact.lastName) {
      backfill.lastName = contact.lastName;
      needsBackfill = true;
    }
    if (needsBackfill) {
      plan.toBackfillName.push(backfill);
    }
    if (inSegment && !needsBackfill) {
      plan.alreadyPresent += 1;
    }
  }

  return plan;
}
