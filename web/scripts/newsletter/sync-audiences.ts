// Reconcile the two cmux Resend audiences from their sources of truth.
//
//   bun run newsletter:sync                 # dry run (default), prints a diff
//   bun run newsletter:sync --apply         # actually write to Resend
//   bun run newsletter:sync --audience users|founders|all
//   bun run newsletter:sync --json          # machine-readable summary only
//
// Audiences (resolved by NAME at runtime, never hardcoded ids):
//   - "cmux Users": union of Stack Auth users with a verified primary email
//     and Stripe Founder's Edition buyers, deduplicated by normalized email.
//   - "cmux Founder's Edition": Stripe Founder's Edition buyers only.
//
// Safety: additive and idempotent. Unsubscribed contacts are never written
// (one-way door), names are only backfilled when missing, contacts are never
// removed, and nothing is written at all without --apply. Requires a Resend
// API key with "Full access" (a sending-only restricted key fails loudly
// with instructions). No email addresses are printed, only counts.
//
// Env (source scripts/load-dev-env.sh or `vercel env pull`): RESEND_API_KEY,
// NEXT_PUBLIC_STACK_PROJECT_ID, STACK_SECRET_SERVER_KEY, STRIPE_SECRET_KEY.

import { parseSyncArgs } from "../../services/newsletter/cli";
import { ResendClient } from "../../services/newsletter/resend-client";
import { listStackContacts } from "../../services/newsletter/stack-source";
import { listFounderContacts } from "../../services/newsletter/stripe-source";
import {
  type AudienceSyncSummary,
  FOUNDERS_AUDIENCE_NAME,
  USERS_AUDIENCE_NAME,
  buildUsersAudienceContacts,
  syncAudience,
} from "../../services/newsletter/sync";

function requiredEnv(name: string): string {
  const value = process.env[name]?.trim();
  if (!value) {
    throw new Error(`Missing required env var ${name}`);
  }
  return value;
}

const args = parseSyncArgs(process.argv.slice(2));

const client = new ResendClient({ apiKey: requiredEnv("RESEND_API_KEY") });

// Founder purchases feed BOTH audiences ("cmux Users" is the union), so the
// Stripe listing is needed for every audience choice.
const stripeResult = await listFounderContacts({
  stripeSecretKey: requiredEnv("STRIPE_SECRET_KEY"),
});

const summaries: AudienceSyncSummary[] = [];
const sourceCounts: Record<string, number> = {
  stripeSessionsScanned: stripeResult.totalSessions,
  founderPurchases: stripeResult.founderSessions,
  founderContacts: stripeResult.contacts.length,
  foundersSkippedMissingEmail: stripeResult.skippedMissingEmail,
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
    await syncAudience({
      client,
      audienceName: USERS_AUDIENCE_NAME,
      desired: buildUsersAudienceContacts(
        stackResult.contacts,
        stripeResult.contacts,
      ),
      apply: args.apply,
    }),
  );
}

if (args.audience === "founders" || args.audience === "all") {
  summaries.push(
    await syncAudience({
      client,
      audienceName: FOUNDERS_AUDIENCE_NAME,
      desired: stripeResult.contacts,
      apply: args.apply,
    }),
  );
}

const machineSummary = {
  dryRun: !args.apply,
  sourceCounts,
  audiences: summaries,
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
    const location = summary.audienceId
      ? summary.audienceId
      : "missing (would be created on --apply)";
    console.log(`  audience "${summary.audienceName}" [${location}]`);
    console.log(
      `    desired=${summary.desiredContacts} existing=${summary.existingContacts} ` +
        `add=${summary.added} backfillName=${summary.nameBackfilled} ` +
        `alreadyPresent=${summary.alreadyPresent} ` +
        `skippedUnsubscribed=${summary.skippedUnsubscribed}` +
        (summary.audienceCreated ? " (audience created)" : ""),
    );
  }
  if (!args.apply) {
    console.log("  dry run only. Re-run with --apply to write these changes.");
  }
  console.log(`summary ${JSON.stringify(machineSummary)}`);
}
