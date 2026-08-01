// Segment sync orchestration: resolve the segment and its topic by name,
// read the global contact state plus the segment's membership, plan the
// minimal mutations (reconcile.ts), and apply them only when explicitly
// asked to.
//
// The two cmux segments overlap by design:
//   - "cmux Users" is the union of Stack Auth signups and Stripe Founder's
//     Edition buyers (a founder may have bought without ever creating a
//     Stack account, so the general list must merge both sources).
//   - "cmux Founder's Edition" is only the Stripe founders, a strict subset
//     for founder-only announcements.
//
// Each segment pairs with a topic that owns its unsubscribe lane: broadcasts
// are created with both segment_id (who is targeted) and topic_id (which
// preference governs suppression), so opting out of general updates does not
// silence founder announcements and vice versa. A contact's GLOBAL
// unsubscribe suppresses everything; the sync treats it as untouchable.
// Topics are created opt-in-by-default and the sync NEVER writes topic
// preferences, so an explicit opt-out is permanent as far as this tooling is
// concerned.

import { type NewsletterContact, mergeContactSources } from "./contacts";
import { planSegmentSync } from "./reconcile";
import type { ResendClient } from "./resend-client";

export const USERS_SEGMENT_NAME = "cmux Users";
export const FOUNDERS_SEGMENT_NAME = "cmux Founder's Edition";

export const USERS_TOPIC = {
  name: "cmux Updates",
  description: "Product updates and announcements for everyone using cmux.",
} as const;
export const FOUNDERS_TOPIC = {
  name: "cmux Founder's Edition",
  description: "Announcements exclusively for Founder's Edition owners.",
} as const;

export function buildUsersSegmentContacts(
  stackContacts: NewsletterContact[],
  founderContacts: NewsletterContact[],
): NewsletterContact[] {
  // Stack listed first: on equally-complete names the Stack display name
  // wins because the user maintains it themselves (see mergeContactSources).
  return mergeContactSources([stackContacts, founderContacts]);
}

export type SegmentSyncSummary = {
  segmentName: string;
  segmentId: string | null;
  segmentCreated: boolean;
  topicName: string;
  topicId: string | null;
  topicCreated: boolean;
  applied: boolean;
  desiredContacts: number;
  existingGlobalContacts: number;
  existingSegmentMembers: number;
  created: number;
  addedToSegment: number;
  nameBackfilled: number;
  alreadyPresent: number;
  skippedUnsubscribed: number;
  // Members of the segment whose email no longer appears in the sources
  // (deleted account, changed primary email, lost verification). Reported
  // for visibility only: the sync is deliberately additive and never
  // removes memberships, because an upstream source glitch must not be
  // able to evacuate an audience. Stale members are pruned by hand in the
  // Resend dashboard when it matters.
  staleSegmentMembers: number;
};

export async function syncSegment(options: {
  client: ResendClient;
  segmentName: string;
  topic: { name: string; description?: string };
  desired: NewsletterContact[];
  // Global contact listing, shared across segment syncs in one run so the
  // (potentially large) account-wide listing happens once.
  existingContacts: Awaited<ReturnType<ResendClient["listContacts"]>>;
  apply: boolean;
}): Promise<SegmentSyncSummary> {
  const { client, segmentName, topic, desired, existingContacts, apply } =
    options;

  // The topic is provisioned alongside its segment so email:draft can always
  // attach a topic_id. Creation is apply-gated like every other write.
  let topicRecord = await client.findTopicByName(topic.name);
  let topicCreated = false;
  if (!topicRecord && apply) {
    topicRecord = await client.createTopic(topic);
    topicCreated = true;
  }
  // default_subscription is immutable after creation and this tooling never
  // subscribes contacts explicitly, so a same-name topic that defaults to
  // opt_out would silently suppress broadcasts for nearly the whole
  // segment. Fail closed instead of adopting it.
  if (topicRecord && topicRecord.defaultSubscription !== "opt_in") {
    throw new Error(
      `Topic "${topic.name}" exists with default_subscription ` +
        `"${topicRecord.defaultSubscription}" but this tooling requires ` +
        '"opt_in" (the setting is immutable). Rename or recreate the topic ' +
        "in the Resend dashboard.",
    );
  }

  let segment = await client.findSegmentByName(segmentName);
  let segmentCreated = false;
  if (!segment && apply) {
    segment = await client.createSegment(segmentName);
    segmentCreated = true;
  }

  const base = {
    segmentName,
    topicName: topic.name,
    topicId: topicRecord?.id ?? null,
    topicCreated,
    desiredContacts: desired.length,
    existingGlobalContacts: existingContacts.length,
  };

  // Missing segment in dry-run mode: report what would happen against an
  // empty membership.
  const memberEmails = new Set<string>(
    segment
      ? (await client.listSegmentContacts(segment.id)).map((contact) =>
          contact.email.trim().toLowerCase(),
        )
      : [],
  );

  const plan = planSegmentSync({
    desired,
    existingContacts: existingContacts.map((contact) => ({
      id: contact.id,
      email: contact.email,
      firstName: contact.first_name ?? undefined,
      lastName: contact.last_name ?? undefined,
      unsubscribed: contact.unsubscribed,
    })),
    segmentMemberEmails: memberEmails,
  });

  if (apply && segment) {
    for (const create of plan.toCreate) {
      await client.createContact({ ...create, segmentIds: [segment.id] });
    }
    for (const add of plan.toAddToSegment) {
      await client.addContactToSegment(add.contactId, segment.id);
    }
    for (const backfill of plan.toBackfillName) {
      await client.updateContactName(backfill.contactId, {
        firstName: backfill.firstName,
        lastName: backfill.lastName,
      });
    }
  }

  const desiredEmails = new Set(
    desired.map((contact) => contact.email.trim().toLowerCase()),
  );
  let staleSegmentMembers = 0;
  for (const memberEmail of memberEmails) {
    if (!desiredEmails.has(memberEmail)) {
      staleSegmentMembers += 1;
    }
  }

  return {
    ...base,
    segmentId: segment?.id ?? null,
    segmentCreated,
    applied: apply && Boolean(segment),
    existingSegmentMembers: memberEmails.size,
    created: plan.toCreate.length,
    addedToSegment: plan.toAddToSegment.length,
    nameBackfilled: plan.toBackfillName.length,
    alreadyPresent: plan.alreadyPresent,
    skippedUnsubscribed: plan.skippedUnsubscribed,
    staleSegmentMembers,
  };
}
