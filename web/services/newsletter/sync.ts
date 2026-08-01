// Audience sync orchestration: resolve the audience by name, read its full
// contact state, plan the minimal mutations (reconcile.ts), and apply them
// only when explicitly asked to.
//
// The two cmux audiences overlap by design:
//   - "cmux Users" is the union of Stack Auth signups and Stripe Founder's
//     Edition buyers (a founder may have bought without ever creating a
//     Stack account, so the general list must merge both sources).
//   - "cmux Founder's Edition" is only the Stripe founders, a strict subset
//     for founder-only announcements.
// Each syncAudience call touches exactly one audience; unsubscribe state is
// per-audience in Resend, and syncing one list never reads or writes the
// other.

import { type NewsletterContact, mergeContactSources } from "./contacts";
import { planAudienceSync } from "./reconcile";
import type { ResendClient } from "./resend-client";

export const USERS_AUDIENCE_NAME = "cmux Users";
export const FOUNDERS_AUDIENCE_NAME = "cmux Founder's Edition";

export function buildUsersAudienceContacts(
  stackContacts: NewsletterContact[],
  founderContacts: NewsletterContact[],
): NewsletterContact[] {
  // Stack listed first: on equally-complete names the Stack display name
  // wins because the user maintains it themselves (see mergeContactSources).
  return mergeContactSources([stackContacts, founderContacts]);
}

export type AudienceSyncSummary = {
  audienceName: string;
  audienceId: string | null;
  audienceCreated: boolean;
  applied: boolean;
  desiredContacts: number;
  existingContacts: number;
  added: number;
  nameBackfilled: number;
  alreadyPresent: number;
  skippedUnsubscribed: number;
};

export async function syncAudience(options: {
  client: ResendClient;
  audienceName: string;
  desired: NewsletterContact[];
  apply: boolean;
}): Promise<AudienceSyncSummary> {
  const { client, audienceName, desired, apply } = options;

  let audience = await client.findAudienceByName(audienceName);
  let audienceCreated = false;
  if (!audience && apply) {
    audience = await client.createAudience(audienceName);
    audienceCreated = true;
  }

  // Missing audience in dry-run mode: report what would happen. Every
  // desired contact would be a create into a brand-new empty audience.
  if (!audience) {
    return {
      audienceName,
      audienceId: null,
      audienceCreated: false,
      applied: false,
      desiredContacts: desired.length,
      existingContacts: 0,
      added: desired.length,
      nameBackfilled: 0,
      alreadyPresent: 0,
      skippedUnsubscribed: 0,
    };
  }

  const existing = await client.listContacts(audience.id);
  const plan = planAudienceSync(desired, [
    ...existing.map((contact) => ({
      id: contact.id,
      email: contact.email,
      firstName: contact.first_name ?? undefined,
      lastName: contact.last_name ?? undefined,
      unsubscribed: contact.unsubscribed,
    })),
  ]);

  if (apply) {
    for (const create of plan.toCreate) {
      await client.createContact(audience.id, create);
    }
    for (const backfill of plan.toBackfillName) {
      await client.updateContactName(audience.id, backfill.contactId, {
        firstName: backfill.firstName,
        lastName: backfill.lastName,
      });
    }
  }

  return {
    audienceName,
    audienceId: audience.id,
    audienceCreated,
    applied: apply,
    desiredContacts: desired.length,
    existingContacts: existing.length,
    added: plan.toCreate.length,
    nameBackfilled: plan.toBackfillName.length,
    alreadyPresent: plan.alreadyPresent,
    skippedUnsubscribed: plan.skippedUnsubscribed,
  };
}
