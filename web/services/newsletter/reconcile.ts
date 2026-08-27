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
//     server-authoritative consent/refund revocations and blocked identity
//     changes are handled by the orchestration layer with separate, exact
//     removal plans.

import {
  PREVIOUS_EMAILS_PROPERTY,
  STACK_USER_ID_PROPERTY,
  previousEmailsFromProperty,
  type NewsletterContact,
} from "./contacts";
import type { ContactPropertyValue } from "./resend-client";

// Existing global contact state read from Resend before any write is planned.
export type ExistingContact = {
  id: string;
  email: string;
  stackUserId?: string;
  properties?: Record<string, ContactPropertyValue> | null;
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

export type ContactPropertiesBackfill = {
  contactId: string;
  email: string;
  properties: Record<string, ContactPropertyValue>;
};

export type IdentityMembershipRemoval = {
  contactId: string;
  email: string;
};

export type SegmentPlan = {
  toCreate: ContactCreate[];
  toAddToSegment: SegmentAdd[];
  toBackfillName: ContactNameBackfill[];
  toBackfillProperties: ContactPropertiesBackfill[];
  toRemoveForIdentityChange: IdentityMembershipRemoval[];
  // Resend does not support editing a contact's email. These are reported so
  // an operator can perform a reviewed provider-side migration without the
  // sync creating a new subscribed contact or silently losing suppression.
  blockedIdentityChanges: number;
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
  const existingByPreviousEmail = new Map<string, ExistingContact>();
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
    for (const previousEmail of previousEmailsFromProperty(
      contact.properties?.[PREVIOUS_EMAILS_PROPERTY],
    )) {
      const prior = existingByPreviousEmail.get(previousEmail);
      if (prior && prior.id !== contact.id) {
        throw new Error(
          "Multiple newsletter contacts claim the same previous email; " +
            "refusing an ambiguous identity reconciliation.",
        );
      }
      existingByPreviousEmail.set(previousEmail, contact);
    }
  }
  const memberEmails = new Set(
    [...options.segmentMemberEmails].map((email) =>
      email.trim().toLowerCase(),
    ),
  );
  const desiredEmails = new Set(
    options.desired.map((contact) => contact.email.trim().toLowerCase()),
  );

  const plan: SegmentPlan = {
    toCreate: [],
    toAddToSegment: [],
    toBackfillName: [],
    toBackfillProperties: [],
    toRemoveForIdentityChange: [],
    blockedIdentityChanges: 0,
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
      // A legacy migration may have recorded this address as an alias. Do not
      // attach a new user (or an identity-less Stripe record) to that contact;
      // Resend email addresses are immutable and alias ownership needs a
      // human-reviewed provider migration.
      if (existingByPreviousEmail.has(desiredEmail)) {
        plan.blockedIdentityChanges += 1;
        continue;
      }
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
      current.stackUserId &&
      current.stackUserId !== contact.stackUserId
    ) {
      throw new Error(
        "A newsletter contact is already linked to a different Stack user; " +
          "refusing to overwrite account identity.",
      );
    }
    // A global unsubscribe is a one-way door. Keep the plan completely empty
    // for this contact, including identity-property backfills and membership
    // cleanup. Apply mode performs the same check again before every write.
    if (current.unsubscribed) {
      plan.skippedUnsubscribed += 1;
      continue;
    }
    if (
      contact.stackUserId &&
      current.stackUserId === contact.stackUserId &&
      current.email.trim().toLowerCase() !== desiredEmail
    ) {
      plan.blockedIdentityChanges += 1;
      const currentEmail = current.email.trim().toLowerCase();
      // Do not continue targeting the old mailbox after Stack has moved the
      // identity. If another active source still claims that address (for
      // example a founder purchase), leave it in place; otherwise remove only
      // this segment membership and require a human-reviewed provider
      // migration before adding the replacement address.
      if (!desiredEmails.has(currentEmail) && memberEmails.has(currentEmail)) {
        plan.toRemoveForIdentityChange.push({
          contactId: current.id,
          email: currentEmail,
        });
      }
      continue;
    }
    if (contact.stackUserId && !current.stackUserId) {
      plan.toBackfillProperties.push({
        contactId: current.id,
        email: desiredEmail,
        properties: { [STACK_USER_ID_PROPERTY]: contact.stackUserId },
      });
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
