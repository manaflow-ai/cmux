// Source A for the "cmux Users" audience: every Stack Auth user with a
// verified primary email, fetched from the Stack server REST API.
//
// Pagination uses Stack's cursor protocol and fails loudly if the cursor
// stops advancing, so a partial listing can never be mistaken for the full
// user base.

import {
  type NewsletterContact,
  normalizeEmail,
  splitDisplayName,
} from "./contacts";
import type { FetchLike } from "./resend-client";
import { fetchSourceJson } from "./source-http";

const STACK_API_BASE = "https://api.stack-auth.com";
const PAGE_LIMIT = 200;
const MAX_PAGES = 10_000;

type StackUser = {
  id?: string;
  primary_email?: string | null;
  primary_email_verified?: boolean;
  display_name?: string | null;
};

type StackUsersPage = {
  items?: StackUser[];
  pagination?: { next_cursor?: string | null };
};

export type StackSourceResult = {
  contacts: NewsletterContact[];
  totalUsers: number;
  skippedMissingOrUnverifiedEmail: number;
};

export async function listStackContacts(options: {
  projectId: string;
  secretServerKey: string;
  fetchImpl?: FetchLike;
  signal?: AbortSignal;
  maxPages?: number;
}): Promise<StackSourceResult> {
  const fetchImpl = options.fetchImpl ?? (fetch as unknown as FetchLike);
  const byEmail = new Map<string, NewsletterContact>();
  let totalUsers = 0;
  let skipped = 0;
  let cursor: string | null = null;
  const seenCursors = new Set<string>();
  let pageCount = 0;

  for (;;) {
    if (cursor && seenCursors.has(cursor)) {
      throw new Error(
        "Stack Auth pagination repeated a cursor; refusing to continue with " +
          "a truncated user listing.",
      );
    }
    if (cursor) seenCursors.add(cursor);
    pageCount += 1;
    if (pageCount > (options.maxPages ?? MAX_PAGES)) {
      throw new Error(
        "Stack Auth pagination exceeded the safety page limit; refusing " +
          "to continue with an unbounded user listing.",
      );
    }
    // include_restricted covers users who signed up but have not finished
    // every onboarding requirement (Stack omits them by default). The
    // verified-primary-email filter below still applies, so unverified
    // restricted users are counted and skipped rather than silently
    // invisible. Anonymous users are deliberately NOT requested: they never
    // signed up with an email.
    const query = new URLSearchParams({
      limit: String(PAGE_LIMIT),
      include_restricted: "true",
    });
    if (cursor) {
      query.set("cursor", cursor);
    }
    const page = await fetchSourceJson<StackUsersPage>({
      fetchImpl,
      url: `${STACK_API_BASE}/api/v1/users?${query.toString()}`,
      headers: {
        "x-stack-access-type": "server",
        "x-stack-project-id": options.projectId,
        "x-stack-secret-server-key": options.secretServerKey,
      },
      label: "Stack Auth user listing",
      signal: options.signal,
    });
    const items = page.items ?? [];
    for (const user of items) {
      totalUsers += 1;
      const email = normalizeEmail(user.primary_email);
      if (!email || user.primary_email_verified !== true) {
        skipped += 1;
        continue;
      }
      if (byEmail.has(email)) {
        continue;
      }
      byEmail.set(email, {
        email,
        ...splitDisplayName(user.display_name),
        sources: ["stack"],
      });
    }
    const nextCursor = page.pagination?.next_cursor ?? null;
    if (!nextCursor) {
      break;
    }
    // Guard against cursor cycles of any length, not just an immediately
    // repeated cursor, so a misbehaving API cannot loop the sync forever.
    if (seenCursors.has(nextCursor) || items.length === 0) {
      throw new Error(
        "Stack Auth pagination made no progress; refusing to continue with " +
          "a truncated user listing.",
      );
    }
    cursor = nextCursor;
  }

  return {
    contacts: [...byEmail.values()],
    totalUsers,
    skippedMissingOrUnverifiedEmail: skipped,
  };
}
