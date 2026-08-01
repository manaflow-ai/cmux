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

const STACK_API_BASE = "https://api.stack-auth.com";
const PAGE_LIMIT = 200;

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
}): Promise<StackSourceResult> {
  const fetchImpl = options.fetchImpl ?? (fetch as unknown as FetchLike);
  const byEmail = new Map<string, NewsletterContact>();
  let totalUsers = 0;
  let skipped = 0;
  let cursor: string | null = null;

  for (;;) {
    const query = new URLSearchParams({ limit: String(PAGE_LIMIT) });
    if (cursor) {
      query.set("cursor", cursor);
    }
    const response = await fetchImpl(
      `${STACK_API_BASE}/api/v1/users?${query.toString()}`,
      {
        method: "GET",
        headers: {
          "x-stack-access-type": "server",
          "x-stack-project-id": options.projectId,
          "x-stack-secret-server-key": options.secretServerKey,
        },
      },
    );
    const text = await response.text();
    if (response.status >= 400) {
      throw new Error(
        `Stack Auth user listing failed with ${response.status}: ${text.slice(0, 200)}`,
      );
    }
    const page = JSON.parse(text) as StackUsersPage;
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
    if (nextCursor === cursor || items.length === 0) {
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
