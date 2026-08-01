// Pure reconciliation: desired contacts (from Stack/Stripe) + existing Resend
// audience state -> minimal set of safe mutations.
//
// Safety invariants, enforced here and covered by
// web/tests/newsletter-reconcile.test.ts:
//   - Unsubscribed contacts are a one-way door. An existing contact with
//     unsubscribed=true is never created, updated, or otherwise written, and
//     no plan entry ever carries an `unsubscribed` field, so a sync can never
//     flip someone back to subscribed.
//   - Updates only backfill missing name fields. A name someone edited in
//     Resend (or that a previous sync wrote) is never overwritten, which also
//     makes re-running the sync a no-op.
//   - Contacts present in Resend but absent from the sources are left alone.
//     The sync only adds; it never removes people from an audience.

import type { NewsletterContact } from "./contacts";

// Existing contact state read from Resend before any write is planned.
export type ExistingContact = {
  id: string;
  email: string;
  firstName?: string;
  lastName?: string;
  unsubscribed: boolean;
};

export type ContactCreate = {
  email: string;
  firstName?: string;
  lastName?: string;
};

export type ContactNameBackfill = {
  contactId: string;
  email: string;
  firstName?: string;
  lastName?: string;
};

export type AudiencePlan = {
  toCreate: ContactCreate[];
  toBackfillName: ContactNameBackfill[];
  alreadyPresent: number;
  skippedUnsubscribed: number;
};

export function planAudienceSync(
  desired: NewsletterContact[],
  existing: ExistingContact[],
): AudiencePlan {
  const existingByEmail = new Map<string, ExistingContact>();
  for (const contact of existing) {
    existingByEmail.set(contact.email.trim().toLowerCase(), contact);
  }

  const plan: AudiencePlan = {
    toCreate: [],
    toBackfillName: [],
    alreadyPresent: 0,
    skippedUnsubscribed: 0,
  };

  for (const contact of desired) {
    const current = existingByEmail.get(contact.email);
    if (!current) {
      plan.toCreate.push({
        email: contact.email,
        ...(contact.firstName ? { firstName: contact.firstName } : {}),
        ...(contact.lastName ? { lastName: contact.lastName } : {}),
      });
      continue;
    }
    if (current.unsubscribed) {
      plan.skippedUnsubscribed += 1;
      continue;
    }
    const backfill: ContactNameBackfill = {
      contactId: current.id,
      email: contact.email,
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
    } else {
      plan.alreadyPresent += 1;
    }
  }

  return plan;
}
