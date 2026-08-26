// Source A for the "cmux Users" audience: Stack Auth users with a verified
// primary email and (in production) explicit server-side newsletter consent,
// fetched from the Stack server REST API.
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
  // Stack exposes custom fields through metadata, not top-level user keys.
  client_metadata?: Record<string, unknown> | null;
  client_read_only_metadata?: Record<string, unknown> | null;
  server_metadata?: Record<string, unknown> | null;
};

type StackUsersPage = {
  items?: StackUser[];
  pagination?: {
    // Stack's current server API follows the Relay-style names. Keep
    // next_cursor as a compatibility fallback for older/test responses, but
    // prefer has_next_page + end_cursor whenever they are present.
    has_next_page?: boolean;
    end_cursor?: string | null;
    next_cursor?: string | null;
  };
};

export function newsletterConsentState(user: {
  client_metadata?: Record<string, unknown> | null;
  client_read_only_metadata?: Record<string, unknown> | null;
  server_metadata?: Record<string, unknown> | null;
}): boolean | null {
  // Only server_metadata is authoritative. Client-writable metadata and
  // aliases are intentionally ignored so a stale client value cannot bypass
  // a server-side revocation. Missing means unknown, not opted out.
  const value = user.server_metadata?.cmuxNewsletterOptIn;
  if (value === true || value === "true") return true;
  if (value === false || value === "false") return false;
  return null;
}

export function hasNewsletterOptIn(user: {
  client_metadata?: Record<string, unknown> | null;
  client_read_only_metadata?: Record<string, unknown> | null;
  server_metadata?: Record<string, unknown> | null;
}): boolean {
  return newsletterConsentState(user) === true;
}

export type StackSourceResult = {
  contacts: NewsletterContact[];
  totalUsers: number;
  skippedMissingOrUnverifiedEmail: number;
  skippedNotOptedIn: number;
  skippedMissingIdentity: number;
  revokedEmails: string[];
  revokedStackUserIds: string[];
};

export async function listStackContacts(options: {
  projectId: string;
  secretServerKey: string;
  fetchImpl?: FetchLike;
  signal?: AbortSignal;
  maxPages?: number;
  requireNewsletterOptIn?: boolean;
}): Promise<StackSourceResult> {
  const fetchImpl = options.fetchImpl ?? (fetch as unknown as FetchLike);
  const byEmail = new Map<string, NewsletterContact>();
  let totalUsers = 0;
  let skipped = 0;
  let skippedNotOptedIn = 0;
  let skippedMissingIdentity = 0;
  const revokedEmails = new Set<string>();
  const revokedStackUserIds = new Set<string>();
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
      const consent = options.requireNewsletterOptIn
        ? newsletterConsentState(user)
        : true;
      // A revocation remains actionable by stable Stack ID even if a user has
      // already changed or cleared the primary email before this run.
      if (consent === false) {
        if (email) revokedEmails.add(email);
        if (user.id?.trim()) revokedStackUserIds.add(user.id.trim());
        continue;
      }
      if (!email || user.primary_email_verified !== true) {
        skipped += 1;
        continue;
      }
      if (options.requireNewsletterOptIn) {
        if (consent !== true) {
          skippedNotOptedIn += 1;
          continue;
        }
        if (!user.id?.trim()) {
          // Without a stable account identity we cannot safely carry a future
          // email change across Resend, so fail closed for this user.
          skippedMissingIdentity += 1;
          continue;
        }
      }
      if (byEmail.has(email)) {
        continue;
      }
      byEmail.set(email, {
        email,
        ...(user.id?.trim() ? { stackUserId: user.id.trim() } : {}),
        ...splitDisplayName(user.display_name),
        sources: ["stack"],
      });
    }
    const pagination = page.pagination;
    const nextCursor =
      pagination?.end_cursor ?? pagination?.next_cursor ?? null;
    // `has_next_page` is authoritative when the current API supplies it. If
    // an older response omits that field, infer continuation from a cursor so
    // existing integrations remain compatible.
    const hasNextPage =
      pagination?.has_next_page ?? Boolean(nextCursor);
    if (!hasNextPage) {
      break;
    }
    // Guard against cursor cycles of any length, not just an immediately
    // repeated cursor, so a misbehaving API cannot loop the sync forever.
    if (!nextCursor || seenCursors.has(nextCursor) || items.length === 0) {
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
    skippedNotOptedIn,
    skippedMissingIdentity,
    revokedEmails: [...revokedEmails],
    revokedStackUserIds: [...revokedStackUserIds],
  };
}
