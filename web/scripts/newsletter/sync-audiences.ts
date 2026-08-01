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

import { parseSyncArgs } from "../../services/newsletter/cli";
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

const args = parseSyncArgs(process.argv.slice(2));

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
  founderContacts: stripeResult.contacts.length,
  foundersSkippedMissingEmail: stripeResult.skippedMissingEmail,
  existingResendContacts: existingContacts.length,
};

if (args.audience === "users" || args.audience === "all") {
  const stackResult = await listStackContacts({
    projectId: requiredEnv("NEXT_PUBLIC_STACK_PROJECT_ID"),
    secretServerKey: requiredEnv("STACK_SECRET_SERVER_KEY"),
  });
  sourceCounts.stackUsersScanned = stackResult.totalUsers;
  sourceCounts.stackContacts = stackResult.contacts.length;
  sourceCounts.stackSkippedMissingOrUnverifiedEmail =
    stackResult.skippedMissingOrUnverifiedEmail;

  summaries.push(
    await syncSegment({
      client,
      segmentName: USERS_SEGMENT_NAME,
      topic: USERS_TOPIC,
      desired: buildUsersSegmentContacts(
        stackResult.contacts,
        stripeResult.contacts,
      ),
      existingContacts,
      apply: args.apply,
    }),
  );
}

if (args.audience === "founders" || args.audience === "all") {
  // Re-list when the users sync just ran with --apply, so contacts it
  // created are visible to the founders plan instead of double-created.
  const contactsForFounders =
    args.apply && summaries.length > 0
      ? await client.listContacts()
      : existingContacts;
  summaries.push(
    await syncSegment({
      client,
      segmentName: FOUNDERS_SEGMENT_NAME,
      topic: FOUNDERS_TOPIC,
      desired: stripeResult.contacts,
      existingContacts: contactsForFounders,
      apply: args.apply,
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
    const location = summary.segmentId
      ? summary.segmentId
      : "missing (would be created on --apply)";
    console.log(`  segment "${summary.segmentName}" [${location}]`);
    console.log(
      `    topic "${summary.topicName}" ${
        summary.topicId ?? "missing (would be created on --apply)"
      }${summary.topicCreated ? " (created)" : ""}`,
    );
    console.log(
      `    desired=${summary.desiredContacts} ` +
        `segmentMembers=${summary.existingSegmentMembers} ` +
        `createContact=${summary.created} ` +
        `addToSegment=${summary.addedToSegment} ` +
        `backfillName=${summary.nameBackfilled} ` +
        `alreadyPresent=${summary.alreadyPresent} ` +
        `skippedUnsubscribed=${summary.skippedUnsubscribed} ` +
        `staleMembers=${summary.staleSegmentMembers}` +
        (summary.segmentCreated ? " (segment created)" : ""),
    );
  }
  if (!args.apply) {
    console.log("  dry run only. Re-run with --apply to write these changes.");
  }
  console.log(`summary ${JSON.stringify(machineSummary)}`);
}
