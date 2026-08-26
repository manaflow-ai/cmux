// Reconcile the two cmux Resend segments (and their unsubscribe topics)
// from their sources of truth.
//
//   bun run newsletter:sync                 # dry run (default), prints a diff
//   bun run newsletter:sync --apply         # actually write to Resend
//   bun run newsletter:sync --audience users|founders|all
//   bun run newsletter:sync --json          # machine-readable summary only
//
// Segments (resolved by NAME at runtime, never hardcoded ids):
//   - "cmux Users": union of Stack Auth users with a verified primary email
//     and Stripe Founder's Edition buyers, deduplicated by normalized email.
//   - "cmux Founder's Edition": Stripe Founder's Edition buyers only.
// Each segment pairs with a topic ("cmux Updates" / "cmux Founder's
// Edition") that owns its unsubscribe lane; topics are created
// opt-in-by-default alongside the segments.
//
// Safety: additive and idempotent. Subscription state is never written (no
// global unsubscribed flag, no topic preferences), globally-unsubscribed
// contacts get no writes at all, names are only backfilled when missing,
// contacts are never removed, and nothing is written without --apply.
// Requires a Resend API key with "Full access" (a sending-only restricted
// key fails loudly with instructions). No email addresses are printed, only
// counts.
//
// Env (source scripts/load-dev-env.sh or `vercel env pull`): RESEND_API_KEY,
// NEXT_PUBLIC_STACK_PROJECT_ID, STACK_SECRET_SERVER_KEY, STRIPE_SECRET_KEY.

import {
  parseSyncArgs,
  requirePrivacyDisclosureConfirmation,
} from "../../services/newsletter/cli";
import {
  PREVIOUS_EMAILS_PROPERTY,
  STACK_USER_ID_PROPERTY,
  previousEmailsFromProperty,
  type NewsletterContact,
} from "../../services/newsletter/contacts";
import { ResendClient } from "../../services/newsletter/resend-client";
import { listStackContacts } from "../../services/newsletter/stack-source";
import { listFounderContacts } from "../../services/newsletter/stripe-source";
import {
  type SegmentSyncSummary,
  FOUNDERS_SEGMENT_NAME,
  FOUNDERS_TOPIC,
  USERS_SEGMENT_NAME,
  USERS_TOPIC,
  buildUsersSegmentContacts,
  syncSegment,
} from "../../services/newsletter/sync";

import { requiredEnv } from "./script-env";

function alignContactsToExistingIdentity(
  desired: NewsletterContact[],
  existing: Awaited<ReturnType<ResendClient["listContacts"]>>,
): NewsletterContact[] {
  const byEmail = new Map(
    existing.map((contact) => [contact.email.trim().toLowerCase(), contact]),
  );
  const byPreviousEmail = new Map<string, (typeof existing)[number]>();
  for (const contact of existing) {
    const previous = contact.properties?.[PREVIOUS_EMAILS_PROPERTY];
    for (const value of previousEmailsFromProperty(previous)) {
      byPreviousEmail.set(value, contact);
    }
  }
  return desired.map((candidate) => {
    const email = candidate.email.trim().toLowerCase();
    const match = byEmail.get(email) ?? byPreviousEmail.get(email);
    const stackUserId = match?.properties?.[STACK_USER_ID_PROPERTY];
    if (!match || typeof stackUserId !== "string") return candidate;
    return {
      ...candidate,
      email: match.email.trim().toLowerCase(),
      stackUserId,
    };
  });
}

const args = parseSyncArgs(process.argv.slice(2));

// Stack Auth users are account holders, not an explicit marketing opt-in
// source. Keep the first production apply fail-closed until the published
// privacy disclosure has been updated (or the source is changed to an
// explicit opt-in list). The deliberately verbose acknowledgement makes this
// boundary visible in automation logs and prevents an accidental --apply.
requirePrivacyDisclosureConfirmation(args);

const client = new ResendClient({ apiKey: requiredEnv("RESEND_API_KEY") });

// Founder purchases feed BOTH segments ("cmux Users" is the union), so the
// Stripe listing is needed for every audience choice.
const stripeResult = await listFounderContacts({
  stripeSecretKey: requiredEnv("STRIPE_SECRET_KEY"),
});

// Contacts are global in Resend; list them once and share across segments.
const existingContacts = await client.listContacts();

const summaries: SegmentSyncSummary[] = [];
const sourceCounts: Record<string, number> = {
  stripeSessionsScanned: stripeResult.totalSessions,
  founderPurchases: stripeResult.founderSessions,
  refundedFounderSessions: stripeResult.refundedSessions,
  refundedFounderContacts: stripeResult.revokedEmails.length,
  founderContacts: stripeResult.contacts.length,
  foundersSkippedMissingEmail: stripeResult.skippedMissingEmail,
  existingResendContacts: existingContacts.length,
};

let usersDesired: ReturnType<typeof buildUsersSegmentContacts> | null = null;
if (args.audience === "users" || args.audience === "all") {
  const stackResult = await listStackContacts({
    projectId: requiredEnv("NEXT_PUBLIC_STACK_PROJECT_ID"),
    secretServerKey: requiredEnv("STACK_SECRET_SERVER_KEY"),
    // Stack account verification is not marketing consent. The source must
    // explicitly mark the user as opted in before any users apply can export
    // the address to the newsletter provider.
    requireNewsletterOptIn: true,
  });
  sourceCounts.stackUsersScanned = stackResult.totalUsers;
  sourceCounts.stackContacts = stackResult.contacts.length;
  sourceCounts.stackSkippedMissingOrUnverifiedEmail =
    stackResult.skippedMissingOrUnverifiedEmail;
  sourceCounts.stackSkippedNotOptedIn = stackResult.skippedNotOptedIn;
  sourceCounts.stackSkippedMissingIdentity = stackResult.skippedMissingIdentity;

  const founderContacts = alignContactsToExistingIdentity(
    stripeResult.contacts,
    existingContacts,
  );
  usersDesired = buildUsersSegmentContacts(
    stackResult.contacts,
    founderContacts,
  );
  summaries.push(
    await syncSegment({
      client,
      segmentName: USERS_SEGMENT_NAME,
      topic: USERS_TOPIC,
      desired: usersDesired,
      existingContacts,
      apply: args.apply,
      // The users segment is the union of Stack opt-ins and founder
      // purchases, so either source can provide an explicit revocation.
      revokedEmails: new Set([
        ...stackResult.revokedEmails,
        ...stripeResult.revokedEmails,
      ]),
      pruneRevoked: args.apply,
    }),
  );
}

if (args.audience === "founders" || args.audience === "all") {
  // The founders plan must see the users sync's effects or a brand-new
  // founder would be double-reported as a create in both segments. In
  // apply mode, re-list the real state; in a dry run, project the users
  // plan onto the listing (planned creates become existing subscribed
  // contacts, planned name backfills are applied) so the preview matches
  // what apply will actually do.
  let contactsForFounders = existingContacts;
  if (usersDesired) {
    if (args.apply) {
      contactsForFounders = await client.listContacts();
    } else {
      const projected = existingContacts.map((contact) => ({ ...contact }));
      const byEmail = new Map(
        projected.map((contact) => [
          contact.email.trim().toLowerCase(),
          contact,
        ]),
      );
      const byStackUserId = new Map(
        projected.flatMap((contact) => {
          const id =
            typeof contact.properties?.[STACK_USER_ID_PROPERTY] === "string"
              ? contact.properties[STACK_USER_ID_PROPERTY]
              : null;
          return id ? [[id, contact] as const] : [];
        }),
      );
      let planned = 0;
      for (const desired of usersDesired) {
        const current =
          (desired.stackUserId
            ? byStackUserId.get(desired.stackUserId)
            : undefined) ?? byEmail.get(desired.email);
        if (!current) {
          const plannedContact = {
            id: `planned_${planned++}`,
            email: desired.email,
            first_name: desired.firstName ?? null,
            last_name: desired.lastName ?? null,
            unsubscribed: false,
            ...(desired.stackUserId
              ? {
                  properties: {
                    [STACK_USER_ID_PROPERTY]: desired.stackUserId,
                  },
                }
              : {}),
          };
          projected.push(plannedContact);
          byEmail.set(desired.email, plannedContact);
          if (desired.stackUserId) {
            byStackUserId.set(desired.stackUserId, plannedContact);
          }
          continue;
        }
        if (current.unsubscribed) {
          continue;
        }
        if (!current.first_name && desired.firstName) {
          current.first_name = desired.firstName;
        }
        if (!current.last_name && desired.lastName) {
          current.last_name = desired.lastName;
        }
        if (current.email.trim().toLowerCase() !== desired.email) {
          byEmail.delete(current.email.trim().toLowerCase());
          current.email = desired.email;
          byEmail.set(desired.email, current);
        }
      }
      contactsForFounders = projected;
    }
  }
  const founderDesired = alignContactsToExistingIdentity(
    stripeResult.contacts,
    contactsForFounders,
  );
  summaries.push(
    await syncSegment({
      client,
      segmentName: FOUNDERS_SEGMENT_NAME,
      topic: FOUNDERS_TOPIC,
      desired: founderDesired,
      existingContacts: contactsForFounders,
      apply: args.apply,
      revokedEmails: new Set(stripeResult.revokedEmails),
      pruneRevoked: args.apply,
    }),
  );
}

const machineSummary = {
  dryRun: !args.apply,
  sourceCounts,
  segments: summaries,
};

if (args.json) {
  console.log(JSON.stringify(machineSummary));
} else {
  const mode = args.apply ? "APPLIED" : "DRY RUN";
  console.log(`newsletter sync (${mode})`);
  for (const [key, value] of Object.entries(sourceCounts)) {
    console.log(`  source ${key}: ${value}`);
  }
  for (const summary of summaries) {
    const location = summary.segmentId ? "present" : "missing";
    console.log(`  segment ${location}`);
    console.log(
      `    preference lane ${summary.topicId ? "present" : "missing"}` +
        (summary.topicCreated ? " (created)" : ""),
    );
    console.log(
      `    desired=${summary.desiredContacts} ` +
        `segmentMembers=${summary.existingSegmentMembers} ` +
        `createContact=${summary.created} ` +
        `addToSegment=${summary.addedToSegment} ` +
        `backfillName=${summary.nameBackfilled} ` +
        `emailMigrated=${summary.emailMigrated} ` +
        `alreadyPresent=${summary.alreadyPresent} ` +
        `skippedUnsubscribed=${summary.skippedUnsubscribed} ` +
        `revokedFromSegment=${summary.revokedFromSegment} ` +
        `staleMembers=${summary.staleSegmentMembers}` +
        (summary.segmentCreated ? " (segment created)" : ""),
    );
  }
  if (!args.apply) {
    console.log("  dry run only. Re-run with --apply to write these changes.");
  }
  console.log(`summary ${JSON.stringify(machineSummary)}`);
}
