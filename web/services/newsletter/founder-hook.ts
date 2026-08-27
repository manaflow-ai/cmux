// Purchase-time segment upsert: when a Founder's Edition checkout completes
// with a successful payment, add the buyer to both cmux segments ("cmux Users"
// is a superset; "cmux Founder's Edition" is the founder-only list).
//
// This path is deliberately best-effort. The caller bounds it with a deadline
// and the reconciliation script is the catch-up mechanism. Subscription state
// is untouchable: a globally unsubscribed contact gets no writes, and the
// latest contact state is re-read immediately before every mutation.

import { isDuplicateContactError, type ResendClient } from "./resend-client";
import { normalizeEmail, splitDisplayName } from "./contacts";
import { FOUNDERS_SEGMENT_NAME, USERS_SEGMENT_NAME } from "./sync";

export type FounderContactUpsertResult = {
  segmentName: string;
  outcome:
    | "created"
    // Membership is idempotent. The name intentionally says "ensured" rather
    // than "added" because a repeated webhook may already have membership.
    | "membership_ensured"
    | "name_backfilled"
    | "skipped_unsubscribed"
    | "skipped_missing_contact"
    | "skipped_missing_segment"
    | "failed";
};

// Bound a best-effort promise with a wall-clock deadline. When the deadline
// fires, the provided controller is aborted so the underlying work (in-flight
// requests, throttle pacing, and 429 backoff) stops rather than continuing
// detached after the caller has answered the webhook.
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
          reject(new Error("newsletter upsert deadline exceeded"));
        }, deadlineMs);
      }),
    ]);
  } finally {
    if (timer) clearTimeout(timer);
  }
}

function resultsFor(
  segmentNames: readonly string[],
  outcome: FounderContactUpsertResult["outcome"],
): FounderContactUpsertResult[] {
  return segmentNames.map((segmentName) => ({ segmentName, outcome }));
}

function isUnsubscribed(contact: { unsubscribed: boolean } | null): boolean {
  return contact?.unsubscribed === true;
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
  const segmentNames = [USERS_SEGMENT_NAME, FOUNDERS_SEGMENT_NAME] as const;

  // Contacts are global: read once, decide once, then resolve both segments.
  let existing = await options.client.getContactByEmail(email);
  if (isUnsubscribed(existing)) {
    return resultsFor(segmentNames, "skipped_unsubscribed");
  }

  const allSegments = await options.client.listSegments();
  const segments = segmentNames.map((segmentName) => {
    const matches = allSegments.filter((segment) => segment.name === segmentName);
    if (matches.length > 1) {
      throw new Error(
        `Segment name "${segmentName}" is ambiguous: ${matches.length} ` +
          "segments share it. Rename or delete the duplicates in the " +
          "provider dashboard.",
      );
    }
    return { segmentName, segment: matches[0] ?? null };
  });

  // Re-read after the potentially paginated segment lookup. This closes the
  // common unsubscribe race before any contact mutation begins.
  existing = await options.client.getContactByEmail(email);
  if (isUnsubscribed(existing)) {
    return resultsFor(segmentNames, "skipped_unsubscribed");
  }

  if (!existing) {
    const segmentIds = segments
      .filter((entry) => entry.segment)
      .map((entry) => entry.segment!.id);
    if (segmentIds.length === 0) {
      return resultsFor(segmentNames, "skipped_missing_segment");
    }
    try {
      await options.client.createContact({ email, ...name, segmentIds });
      return segments.map((entry) => ({
        segmentName: entry.segmentName,
        outcome: entry.segment ? "created" : "skipped_missing_segment",
      }));
    } catch (error) {
      // A concurrent webhook may have created the global contact between our
      // GET and POST. Recover only that duplicate race, then continue through
      // the existing-contact path so both segment memberships are attempted.
      if (!isDuplicateContactError(error)) throw error;
      existing = await options.client.getContactByEmail(email);
      if (!existing) throw error;
      if (existing.unsubscribed) {
        return resultsFor(segmentNames, "skipped_unsubscribed");
      }
    }
  }

  if (!existing) {
    return resultsFor(segmentNames, "skipped_missing_contact");
  }

  // Backfill missing names, but re-read immediately before the PATCH. A
  // contact can unsubscribe while this request is in flight; in that case no
  // write is attempted and the caller receives an explicit skip outcome.
  let nameBackfilled = false;
  if (
    (!existing.first_name && name.firstName) ||
    (!existing.last_name && name.lastName)
  ) {
    const latest = await options.client.getContactByEmail(email);
    if (!latest) return resultsFor(segmentNames, "skipped_missing_contact");
    if (latest.unsubscribed) {
      return resultsFor(segmentNames, "skipped_unsubscribed");
    }
    existing = latest;
    // Compute the PATCH from the fresh read, not from the stale snapshot that
    // triggered the re-read, so a concurrent name edit can never be replaced.
    const backfill: { firstName?: string; lastName?: string } = {};
    if (!latest.first_name && name.firstName) backfill.firstName = name.firstName;
    if (!latest.last_name && name.lastName) backfill.lastName = name.lastName;
    try {
      if (backfill.firstName || backfill.lastName) {
        await options.client.updateContactName(existing.id, backfill);
        nameBackfilled = true;
      }
    } catch {
      // Keep attempting segment membership; the next reconciliation can retry
      // the name backfill. Per-segment results still report failed adds below.
      nameBackfilled = false;
    }
  }

  const results: FounderContactUpsertResult[] = [];
  for (const entry of segments) {
    if (!entry.segment) {
      results.push({
        segmentName: entry.segmentName,
        outcome: "skipped_missing_segment",
      });
      continue;
    }

    // Re-read before every membership mutation to preserve the one-way
    // unsubscribe guarantee across the whole webhook operation.
    const latest = await options.client.getContactByEmail(email);
    if (!latest) {
      results.push({
        segmentName: entry.segmentName,
        outcome: "skipped_missing_contact",
      });
      continue;
    }
    if (latest.unsubscribed) {
      results.push({
        segmentName: entry.segmentName,
        outcome: "skipped_unsubscribed",
      });
      continue;
    }
    try {
      await options.client.addContactToSegment(latest.id, entry.segment.id);
      results.push({
        segmentName: entry.segmentName,
        outcome: nameBackfilled ? "name_backfilled" : "membership_ensured",
      });
    } catch {
      // Do not abort the second segment when the first provider call fails.
      results.push({ segmentName: entry.segmentName, outcome: "failed" });
    }
  }
  return results;
}
