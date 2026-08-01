// Purchase-time audience upsert: when a Founder's Edition checkout completes,
// add the buyer to both Resend audiences ("cmux Users" is a superset that
// includes founders; "cmux Founder's Edition" is the founders-only list).
//
// This keeps the audiences fresh between manual runs of
// web/scripts/newsletter/sync-audiences.ts without any new cron surface: the
// existing Stripe-signature-gated webhook is the trigger. Failures here are
// best-effort by contract; the caller logs and still acknowledges the
// webhook, and the reconciliation script is the catch-up mechanism.
//
// The same one-way-door rule as the sync applies: an existing contact who
// unsubscribed is never touched, and an existing subscribed contact only has
// missing name fields backfilled.

import { normalizeEmail, splitDisplayName } from "./contacts";
import type { ResendClient } from "./resend-client";
import { FOUNDERS_AUDIENCE_NAME, USERS_AUDIENCE_NAME } from "./sync";

export type FounderContactUpsertResult = {
  audienceName: string;
  outcome:
    | "created"
    | "name_backfilled"
    | "already_present"
    | "skipped_unsubscribed"
    | "skipped_missing_audience";
};

export async function upsertFounderIntoAudiences(options: {
  client: ResendClient;
  email: string;
  customerName?: string | null;
}): Promise<FounderContactUpsertResult[]> {
  const email = normalizeEmail(options.email);
  if (!email) {
    throw new Error("Founder contact upsert requires a valid email");
  }
  const name = splitDisplayName(options.customerName);

  const results: FounderContactUpsertResult[] = [];
  for (const audienceName of [USERS_AUDIENCE_NAME, FOUNDERS_AUDIENCE_NAME]) {
    // Audiences are provisioned by the sync script (or by hand); the webhook
    // never creates them, so a typo'd or not-yet-created audience shows up
    // as an explicit skip in the logs instead of a surprise new list.
    const audience = await options.client.findAudienceByName(audienceName);
    if (!audience) {
      results.push({ audienceName, outcome: "skipped_missing_audience" });
      continue;
    }
    const existing = await options.client.getContactByEmail(audience.id, email);
    if (!existing) {
      await options.client.createContact(audience.id, { email, ...name });
      results.push({ audienceName, outcome: "created" });
      continue;
    }
    if (existing.unsubscribed) {
      results.push({ audienceName, outcome: "skipped_unsubscribed" });
      continue;
    }
    const backfill: { firstName?: string; lastName?: string } = {};
    if (!existing.first_name && name.firstName) {
      backfill.firstName = name.firstName;
    }
    if (!existing.last_name && name.lastName) {
      backfill.lastName = name.lastName;
    }
    if (backfill.firstName || backfill.lastName) {
      await options.client.updateContactName(audience.id, existing.id, backfill);
      results.push({ audienceName, outcome: "name_backfilled" });
    } else {
      results.push({ audienceName, outcome: "already_present" });
    }
  }
  return results;
}
