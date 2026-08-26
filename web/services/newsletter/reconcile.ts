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
//     The sync never removes them based on an incomplete source. Explicit
//     server-authoritative consent/refund revocations are handled by the
//     orchestration layer with a separate, exact removal plan.

import type { NewsletterContact } from "./contacts";

// Existing global contact state read from Resend before any write is planned.
export type ExistingContact = {
  id: string;
  email: string;
  stackUserId?: string;
  firstName?: string;
  lastName?: string;
  unsubscribed: boolean;
};

// Create a new global contact, placed directly into the target segment.
export type ContactCreate = {
  email: string;
  stackUserId?: string;
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

export type ContactEmailUpdate = {
  contactId: string;
  previousEmail: string;
  email: string;
  stackUserId: string;
};

export type SegmentPlan = {
  toCreate: ContactCreate[];
  toAddToSegment: SegmentAdd[];
  toBackfillName: ContactNameBackfill[];
  toUpdateEmail: ContactEmailUpdate[];
  alreadyPresent: number;
  skippedUnsubscribed: number;
};

export function planSegmentSync(options: {
  desired: NewsletterContact[];
  existingContacts: ExistingContact[];
  segmentMemberEmails: ReadonlySet<string>;
}): SegmentPlan {
  const existingByEmail = new Map<string, ExistingContact>();
  const existingByStackUserId = new Map<string, ExistingContact>();
  for (const contact of options.existingContacts) {
    const email = contact.email.trim().toLowerCase();
    existingByEmail.set(email, contact);
    if (contact.stackUserId) {
      if (existingByStackUserId.has(contact.stackUserId)) {
        throw new Error(
          "Multiple newsletter contacts carry the same Stack user identity; " +
            "refusing to reconcile an ambiguous account.",
        );
      }
      existingByStackUserId.set(contact.stackUserId, contact);
    }
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
    toUpdateEmail: [],
    alreadyPresent: 0,
    skippedUnsubscribed: 0,
  };

  for (const contact of options.desired) {
    // Desired emails come pre-normalized from the sources, but enforce the
    // invariant at the keying site too so a future source cannot silently
    // break case-insensitive matching.
    const desiredEmail = contact.email.trim().toLowerCase();
    const current =
      (contact.stackUserId
        ? existingByStackUserId.get(contact.stackUserId)
        : undefined) ?? existingByEmail.get(desiredEmail);
    const emailOwner = existingByEmail.get(desiredEmail);
    if (current && emailOwner && emailOwner.id !== current.id) {
      throw new Error(
        "A desired newsletter email belongs to a different contact than its " +
          "Stack identity; refusing an ambiguous migration.",
      );
    }
    if (!current) {
      plan.toCreate.push({
        email: desiredEmail,
        ...(contact.stackUserId ? { stackUserId: contact.stackUserId } : {}),
        ...(contact.firstName ? { firstName: contact.firstName } : {}),
        ...(contact.lastName ? { lastName: contact.lastName } : {}),
      });
      continue;
    }
    if (
      contact.stackUserId &&
      current.stackUserId === contact.stackUserId &&
      current.email.trim().toLowerCase() !== desiredEmail
    ) {
      plan.toUpdateEmail.push({
        contactId: current.id,
        previousEmail: current.email.trim().toLowerCase(),
        email: desiredEmail,
        stackUserId: contact.stackUserId,
      });
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
