// Purchase-time segment upsert: when a Founder's Edition checkout completes
// with a successful payment, add the buyer to both cmux segments ("cmux
// Users" is a superset that includes founders; "cmux Founder's Edition" is
// the founders-only list).
//
// This keeps the segments fresh between manual runs of
// web/scripts/newsletter/sync-audiences.ts without any new cron surface: the
// existing Stripe-signature-gated webhook is the trigger. Failures here are
// best-effort by contract; the caller logs and still acknowledges the
// webhook, and the reconciliation script is the catch-up mechanism. The
// caller also bounds the whole upsert with a deadline (see withDeadline) so
// a Resend stall can never hold the webhook open past its response.
//
// Subscription state is untouchable here, same as in the sync: a contact
// with global unsubscribed=true gets no writes at all, topic preferences are
// never written, and an existing subscribed contact only has missing name
// fields backfilled.

import { normalizeEmail, splitDisplayName } from "./contacts";
import type { ResendClient } from "./resend-client";
import { FOUNDERS_SEGMENT_NAME, USERS_SEGMENT_NAME } from "./sync";

// "added_to_segment" also covers re-adding an existing member: Resend
// treats that as a no-op and reporting it separately would require an extra
// membership read per webhook for telemetry-only value.
export type FounderContactUpsertResult = {
  segmentName: string;
  outcome:
    | "created"
    | "added_to_segment"
    | "name_backfilled"
    | "skipped_unsubscribed"
    | "skipped_missing_segment";
};

// Bound a best-effort promise with a wall-clock deadline. When the deadline
// fires, the provided controller is aborted so the underlying work
// (in-flight requests, throttle pacing, 429 backoff in ResendClient) stops
// instead of continuing detached after the caller has answered the webhook.
export async function withDeadline<T>(
  work: Promise<T>,
  deadlineMs: number,
  abortOnTimeout?: AbortController,
): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([
      work,
      new Promise<never>((_, reject) => {
        timer = setTimeout(() => {
          abortOnTimeout?.abort();
          reject(
            new Error(`newsletter upsert exceeded ${deadlineMs}ms deadline`),
          );
        }, deadlineMs);
      }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}

export async function upsertFounderIntoSegments(options: {
  client: ResendClient;
  email: string;
  customerName?: string | null;
}): Promise<FounderContactUpsertResult[]> {
  const email = normalizeEmail(options.email);
  if (!email) {
    throw new Error("Founder contact upsert requires a valid email");
  }
  const name = splitDisplayName(options.customerName);
  const segmentNames = [USERS_SEGMENT_NAME, FOUNDERS_SEGMENT_NAME];

  // Contacts are global: read once, decide once, then apply per segment.
  const existing = await options.client.getContactByEmail(email);
  if (existing?.unsubscribed) {
    return segmentNames.map((segmentName) => ({
      segmentName,
      outcome: "skipped_unsubscribed",
    }));
  }

  // Segments are provisioned by the sync script (or by hand); the webhook
  // never creates them, so a typo'd or not-yet-created segment shows up as
  // an explicit skip in the logs instead of a surprise new list. One
  // listing resolves both names (same ambiguity rule as findSegmentByName),
  // keeping this deadline-bounded path to a single paginated read.
  const allSegments = await options.client.listSegments();
  const segments = segmentNames.map((segmentName) => {
    const matches = allSegments.filter((s) => s.name === segmentName);
    if (matches.length > 1) {
      throw new Error(
        `Segment name "${segmentName}" is ambiguous: ${matches.length} ` +
          "segments share it. Rename or delete the duplicates in the " +
          "Resend dashboard.",
      );
    }
    return { segmentName, segment: matches[0] ?? null };
  });

  const results: FounderContactUpsertResult[] = [];
  if (!existing) {
    const segmentIds = segments
      .filter((entry) => entry.segment)
      .map((entry) => entry.segment!.id);
    if (segmentIds.length > 0) {
      await options.client.createContact({ email, ...name, segmentIds });
    }
    for (const entry of segments) {
      results.push({
        segmentName: entry.segmentName,
        outcome: entry.segment ? "created" : "skipped_missing_segment",
      });
    }
    return results;
  }

  const backfill: { firstName?: string; lastName?: string } = {};
  if (!existing.first_name && name.firstName) {
    backfill.firstName = name.firstName;
  }
  if (!existing.last_name && name.lastName) {
    backfill.lastName = name.lastName;
  }
  if (backfill.firstName || backfill.lastName) {
    await options.client.updateContactName(existing.id, backfill);
  }

  for (const entry of segments) {
    if (!entry.segment) {
      results.push({
        segmentName: entry.segmentName,
        outcome: "skipped_missing_segment",
      });
      continue;
    }
    // Membership add is idempotent from our perspective; Resend treats a
    // re-add of an existing member as a no-op rather than an error.
    await options.client.addContactToSegment(existing.id, entry.segment.id);
    results.push({
      segmentName: entry.segmentName,
      outcome:
        backfill.firstName || backfill.lastName
          ? "name_backfilled"
          : "added_to_segment",
    });
  }
  return results;
}
