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

import {
  STACK_USER_ID_PROPERTY,
  PREVIOUS_EMAILS_PROPERTY,
  previousEmailsFromProperty,
  previousEmailsPropertyValue,
  type NewsletterContact,
  mergeContactSources,
} from "./contacts";
import { planSegmentSync } from "./reconcile";
import {
  isDuplicateContactError,
  type ResendClient,
} from "./resend-client";

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
  emailMigrated: number;
  alreadyPresent: number;
  skippedUnsubscribed: number;
  revokedFromSegment: number;
  // Members of the segment whose email no longer appears in the sources
  // (deleted account, changed primary email, lost verification). Reported for
  // visibility only: an untrusted/missing source never evacuates an audience.
  // Explicit server-authoritative consent revocations are tracked separately
  // and removed safely when apply mode is enabled.
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
  // Exact, server-authoritative consent revocations from a complete source
  // listing. Unknown/missing source data is never treated as a revocation.
  revokedEmails?: ReadonlySet<string>;
  pruneRevoked?: boolean;
  // Contact identity migration is planned from the stable Stack id stored in
  // Resend properties, preserving unsubscribe state across email changes.
}): Promise<SegmentSyncSummary> {
  const {
    client,
    segmentName,
    topic,
    desired,
    existingContacts,
    apply,
  } = options;

  // Resolve both resources before provisioning either one. In particular, a
  // duplicate segment name must fail before an apply run creates a topic as a
  // side effect.
  let segment = await client.findSegmentByName(segmentName);
  let topicRecord = await client.findTopicByName(topic.name);
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

  let topicCreated = false;
  let segmentCreated = false;
  if (!segment && apply) {
    segment = await client.createSegment(segmentName);
    segmentCreated = true;
  }
  // Creation is apply-gated like every other write. The topic is created only
  // after the segment lookup above has passed its ambiguity guard.
  if (!topicRecord && apply) {
    topicRecord = await client.createTopic(topic);
    topicCreated = true;
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
  const segmentMembers = segment
    ? await client.listSegmentContacts(segment.id)
    : [];
  const memberEmails = new Set<string>(
    segmentMembers.map((contact) => contact.email.trim().toLowerCase()),
  );

  const plan = planSegmentSync({
    desired,
    existingContacts: existingContacts.map((contact) => ({
      id: contact.id,
      email: contact.email,
      stackUserId:
        typeof contact.properties?.[STACK_USER_ID_PROPERTY] === "string"
          ? contact.properties[STACK_USER_ID_PROPERTY]
          : undefined,
      properties: contact.properties,
      firstName: contact.first_name ?? undefined,
      lastName: contact.last_name ?? undefined,
      unsubscribed: contact.unsubscribed,
    })),
    segmentMemberEmails: memberEmails,
  });
  const initialSegmentMemberCount = memberEmails.size;
  const desiredEmails = new Set(
    desired.map((contact) => contact.email.trim().toLowerCase()),
  );
  const revokedEmails = new Set(
    [...(options.revokedEmails ?? [])].map((email) =>
      email.trim().toLowerCase(),
    ),
  );
  const revokedToRemove = segmentMembers
    .filter((member) => {
      const email = member.email.trim().toLowerCase();
      const previousEmails = previousEmailsFromProperty(
        member.properties?.[PREVIOUS_EMAILS_PROPERTY],
      );
      const wasRevoked =
        revokedEmails.has(email) ||
        previousEmails.some((previous) =>
          revokedEmails.has(previous.trim().toLowerCase()),
        );
      // An active source (for example a Stack opt-in or another paid founder
      // purchase) keeps the current address in the segment even if an older
      // alias appears in a refund/revocation feed.
      return wasRevoked && !desiredEmails.has(email);
    })
    .map((member) => member.email.trim().toLowerCase());
  // Dry runs report the exact planned removals; apply mode performs them below.
  const revokedFromSegment = revokedToRemove.length;
  let createdCount = plan.toCreate.length;
  let addedToSegmentCount = plan.toAddToSegment.length;
  let nameBackfilledCount = plan.toBackfillName.length;
  let emailMigratedCount = plan.toUpdateEmail.length;

  if (apply && segment) {
    createdCount = 0;
    addedToSegmentCount = 0;
    nameBackfilledCount = 0;
    emailMigratedCount = 0;
    if (options.pruneRevoked) {
      const existingByEmail = new Map(
        existingContacts.map((contact) => [
          contact.email.trim().toLowerCase(),
          contact,
        ]),
      );
      for (const email of revokedToRemove) {
        const contact = existingByEmail.get(email);
        if (!contact || !memberEmails.has(email)) continue;
        const latest = await client.getContactByEmail(email);
        if (!latest || latest.unsubscribed) continue;
        await client.removeContactFromSegment(latest.id, segment.id);
        memberEmails.delete(email);
      }
    }
    for (const propertyBackfill of plan.toBackfillProperties) {
      const latest = await client.getContactById(propertyBackfill.contactId);
      if (!latest || latest.unsubscribed) continue;
      await client.updateContactProperties(latest.id, {
        ...(latest.properties ?? {}),
        ...propertyBackfill.properties,
      });
    }
    for (const update of plan.toUpdateEmail) {
      const latest = await client.getContactById(update.contactId);
      if (!latest || latest.unsubscribed) continue;
      const previousEmails = new Set<string>([
        ...update.previousEmails,
        ...previousEmailsFromProperty(
          latest.properties?.[PREVIOUS_EMAILS_PROPERTY],
        ),
      ]);
      await client.updateContactEmail(latest.id, update.email, {
        ...(latest.properties ?? {}),
        [STACK_USER_ID_PROPERTY]: update.stackUserId,
        [PREVIOUS_EMAILS_PROPERTY]: previousEmailsPropertyValue(
          [...previousEmails],
        ),
      });
      if (memberEmails.delete(update.previousEmail)) {
        memberEmails.add(update.email);
      }
      emailMigratedCount += 1;
    }
    for (const create of plan.toCreate) {
      // Re-read immediately before creating. A contact can be unsubscribed or
      // created by another sync after the initial global listing.
      const latest = await client.getContactByEmail(create.email);
      if (latest?.unsubscribed) continue;
      if (latest) {
        if (!memberEmails.has(create.email)) {
          await client.addContactToSegment(latest.id, segment.id);
          memberEmails.add(create.email);
          addedToSegmentCount += 1;
        }
        continue;
      }
      try {
        await client.createContact({
          ...create,
          ...(create.stackUserId
            ? { properties: { [STACK_USER_ID_PROPERTY]: create.stackUserId } }
            : {}),
          segmentIds: [segment.id],
        });
        memberEmails.add(create.email);
        createdCount += 1;
      } catch (error) {
        if (!isDuplicateContactError(error)) throw error;
        // Another worker won the create race. Re-read before any follow-up
        // membership write and leave an unsubscribed winner untouched.
        const raced = await client.getContactByEmail(create.email);
        if (raced && !raced.unsubscribed && !memberEmails.has(create.email)) {
          await client.addContactToSegment(raced.id, segment.id);
          memberEmails.add(create.email);
          addedToSegmentCount += 1;
        }
      }
    }
    for (const add of plan.toAddToSegment) {
      if (memberEmails.has(add.email)) continue;
      const latest = await client.getContactByEmail(add.email);
      if (!latest || latest.unsubscribed) continue;
      await client.addContactToSegment(latest.id, segment.id);
      memberEmails.add(add.email);
      addedToSegmentCount += 1;
    }
    for (const backfill of plan.toBackfillName) {
      const latest = await client.getContactByEmail(backfill.email);
      if (!latest || latest.unsubscribed) continue;
      // Preserve the current contact value if another actor filled it while
      // this run was in flight; only send fields that are still missing.
      const firstName = !latest.first_name ? backfill.firstName : undefined;
      const lastName = !latest.last_name ? backfill.lastName : undefined;
      if (firstName || lastName) {
        await client.updateContactName(latest.id, {
          firstName,
          lastName,
        });
        nameBackfilledCount += 1;
      }
    }
  }

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
    existingSegmentMembers: initialSegmentMemberCount,
    created: createdCount,
    addedToSegment: addedToSegmentCount,
    nameBackfilled: nameBackfilledCount,
    emailMigrated: emailMigratedCount,
    alreadyPresent: plan.alreadyPresent,
    skippedUnsubscribed: plan.skippedUnsubscribed,
    revokedFromSegment,
    staleSegmentMembers,
  };
}
