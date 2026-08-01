import { describe, expect, test } from "bun:test";

// End-to-end sync behavior against a fake in-memory Resend API: audience
// resolution by name, dry-run purity (zero writes), apply writing exactly
// the plan, unsubscribe protection, contact pagination, and the restricted
// API key error.

import type { NewsletterContact } from "../services/newsletter/contacts";
import {
  ResendApiError,
  ResendClient,
  type FetchLike,
} from "../services/newsletter/resend-client";
import {
  FOUNDERS_AUDIENCE_NAME,
  USERS_AUDIENCE_NAME,
  buildUsersAudienceContacts,
  syncAudience,
} from "../services/newsletter/sync";

type FakeContact = {
  id: string;
  email: string;
  first_name?: string | null;
  last_name?: string | null;
  unsubscribed: boolean;
};

type FakeResend = {
  audiences: { id: string; name: string }[];
  contacts: Map<string, FakeContact[]>;
  writes: string[];
  contactPageSize?: number;
  fetchImpl: FetchLike;
};

function fakeResend(options?: { contactPageSize?: number }): FakeResend {
  const state: FakeResend = {
    audiences: [],
    contacts: new Map(),
    writes: [],
    contactPageSize: options?.contactPageSize,
    fetchImpl: undefined as unknown as FetchLike,
  };
  let nextId = 1;

  state.fetchImpl = async (url, init) => {
    const method = init?.method ?? "GET";
    const { pathname, searchParams } = new URL(url);
    const respond = (status: number, body: unknown) => ({
      status,
      headers: { get: () => null },
      text: async () => JSON.stringify(body),
    });

    if (method === "GET" && pathname === "/audiences") {
      return respond(200, { data: state.audiences, has_more: false });
    }
    if (method === "POST" && pathname === "/audiences") {
      const { name } = JSON.parse(init?.body ?? "{}") as { name: string };
      const audience = { id: `aud_${nextId++}`, name };
      state.audiences.push(audience);
      state.contacts.set(audience.id, []);
      state.writes.push(`create-audience:${name}`);
      return respond(200, audience);
    }

    const contactsMatch = pathname.match(/^\/audiences\/([^/]+)\/contacts$/);
    if (contactsMatch) {
      const audienceId = contactsMatch[1];
      const all = state.contacts.get(audienceId) ?? [];
      if (method === "GET") {
        const pageSize = state.contactPageSize ?? 1000;
        const after = searchParams.get("after");
        const startIndex = after
          ? all.findIndex((c) => c.id === after) + 1
          : 0;
        const page = all.slice(startIndex, startIndex + pageSize);
        return respond(200, {
          data: page,
          has_more: startIndex + page.length < all.length,
        });
      }
      if (method === "POST") {
        const body = JSON.parse(init?.body ?? "{}") as {
          email: string;
          first_name?: string;
          last_name?: string;
          unsubscribed?: boolean;
        };
        // The sync must never send an unsubscribed flag on create.
        expect("unsubscribed" in body).toBe(false);
        const created: FakeContact = {
          id: `con_${nextId++}`,
          email: body.email,
          first_name: body.first_name ?? null,
          last_name: body.last_name ?? null,
          unsubscribed: false,
        };
        all.push(created);
        state.writes.push(`create-contact:${audienceId}:${body.email}`);
        return respond(200, { id: created.id });
      }
    }

    const contactMatch = pathname.match(
      /^\/audiences\/([^/]+)\/contacts\/([^/]+)$/,
    );
    if (contactMatch) {
      const audienceId = contactMatch[1];
      const key = decodeURIComponent(contactMatch[2]);
      const all = state.contacts.get(audienceId) ?? [];
      const found = all.find((c) => c.id === key || c.email === key);
      if (method === "GET") {
        return found
          ? respond(200, found)
          : respond(404, { name: "not_found", message: "Contact not found" });
      }
      if (method === "PATCH") {
        if (!found) {
          return respond(404, { name: "not_found", message: "Contact not found" });
        }
        const body = JSON.parse(init?.body ?? "{}") as {
          first_name?: string;
          last_name?: string;
          unsubscribed?: boolean;
        };
        expect("unsubscribed" in body).toBe(false);
        if (body.first_name) found.first_name = body.first_name;
        if (body.last_name) found.last_name = body.last_name;
        state.writes.push(`patch-contact:${audienceId}:${found.email}`);
        return respond(200, { id: found.id });
      }
    }

    return respond(500, { message: `unhandled ${method} ${pathname}` });
  };

  return state;
}

function client(fake: FakeResend): ResendClient {
  return new ResendClient({
    apiKey: "re_full_access_test",
    fetchImpl: fake.fetchImpl,
    writeSpacingMs: 0,
  });
}

function contact(email: string, firstName?: string): NewsletterContact {
  return { email, ...(firstName ? { firstName } : {}), sources: ["stack"] };
}

describe("syncAudience", () => {
  test("dry run performs zero writes and reports the diff", async () => {
    const fake = fakeResend();
    fake.audiences.push({ id: "aud_users", name: USERS_AUDIENCE_NAME });
    fake.contacts.set("aud_users", [
      {
        id: "con_1",
        email: "present@example.com",
        first_name: "P",
        unsubscribed: false,
      },
      { id: "con_2", email: "unsub@example.com", unsubscribed: true },
    ]);

    const summary = await syncAudience({
      client: client(fake),
      audienceName: USERS_AUDIENCE_NAME,
      desired: [
        contact("present@example.com"),
        contact("unsub@example.com"),
        contact("new@example.com", "New"),
      ],
      apply: false,
    });

    expect(fake.writes).toEqual([]);
    expect(summary).toMatchObject({
      applied: false,
      audienceId: "aud_users",
      added: 1,
      alreadyPresent: 1,
      skippedUnsubscribed: 1,
    });
  });

  test("dry run against a missing audience reports without creating it", async () => {
    const fake = fakeResend();
    const summary = await syncAudience({
      client: client(fake),
      audienceName: FOUNDERS_AUDIENCE_NAME,
      desired: [contact("a@example.com")],
      apply: false,
    });
    expect(fake.writes).toEqual([]);
    expect(summary.audienceId).toBeNull();
    expect(summary.added).toBe(1);
  });

  test("apply creates the audience, adds contacts, and never touches unsubscribed", async () => {
    const fake = fakeResend();
    fake.audiences.push({ id: "aud_users", name: USERS_AUDIENCE_NAME });
    fake.contacts.set("aud_users", [
      { id: "con_2", email: "unsub@example.com", unsubscribed: true },
      { id: "con_3", email: "noname@example.com", unsubscribed: false },
    ]);

    const summary = await syncAudience({
      client: client(fake),
      audienceName: USERS_AUDIENCE_NAME,
      desired: [
        contact("unsub@example.com", "Should NotWrite"),
        { email: "noname@example.com", firstName: "Nova", sources: ["stripe"] },
        contact("new@example.com", "New"),
      ],
      apply: true,
    });

    expect(fake.writes).toEqual([
      "create-contact:aud_users:new@example.com",
      "patch-contact:aud_users:noname@example.com",
    ]);
    expect(summary).toMatchObject({
      applied: true,
      added: 1,
      nameBackfilled: 1,
      skippedUnsubscribed: 1,
    });
    const unsub = fake.contacts
      .get("aud_users")!
      .find((c) => c.email === "unsub@example.com");
    expect(unsub?.unsubscribed).toBe(true);
    expect(unsub?.first_name ?? null).toBeNull();
  });

  test("apply creates a missing audience by name", async () => {
    const fake = fakeResend();
    const summary = await syncAudience({
      client: client(fake),
      audienceName: FOUNDERS_AUDIENCE_NAME,
      desired: [contact("founder@example.com")],
      apply: true,
    });
    expect(summary.audienceCreated).toBe(true);
    expect(fake.writes[0]).toBe(
      `create-audience:${FOUNDERS_AUDIENCE_NAME}`,
    );
    expect(fake.audiences.map((a) => a.name)).toContain(
      FOUNDERS_AUDIENCE_NAME,
    );
  });

  test("ambiguous audience names fail loudly", async () => {
    const fake = fakeResend();
    fake.audiences.push(
      { id: "aud_1", name: USERS_AUDIENCE_NAME },
      { id: "aud_2", name: USERS_AUDIENCE_NAME },
    );
    await expect(
      syncAudience({
        client: client(fake),
        audienceName: USERS_AUDIENCE_NAME,
        desired: [],
        apply: false,
      }),
    ).rejects.toThrow(/ambiguous/);
  });

  test("reads the full contact list across pages before planning", async () => {
    const fake = fakeResend({ contactPageSize: 2 });
    fake.audiences.push({ id: "aud_users", name: USERS_AUDIENCE_NAME });
    fake.contacts.set(
      "aud_users",
      Array.from({ length: 5 }, (_, i) => ({
        id: `con_${i}`,
        email: `existing${i}@example.com`,
        unsubscribed: false,
      })),
    );

    const summary = await syncAudience({
      client: client(fake),
      audienceName: USERS_AUDIENCE_NAME,
      // All five already exist; a truncated read would plan spurious creates.
      desired: Array.from({ length: 5 }, (_, i) =>
        contact(`existing${i}@example.com`),
      ),
      apply: true,
    });

    expect(summary.existingContacts).toBe(5);
    expect(summary.added).toBe(0);
    expect(fake.writes).toEqual([]);
  });
});

describe("ResendClient error handling", () => {
  test("explains the restricted (sending-only) API key failure", async () => {
    const restrictedFetch: FetchLike = async () => ({
      status: 401,
      headers: { get: () => null },
      text: async () =>
        JSON.stringify({
          statusCode: 401,
          message: "This API key is restricted to only send emails",
          name: "restricted_api_key",
        }),
    });
    const restricted = new ResendClient({
      apiKey: "re_restricted",
      fetchImpl: restrictedFetch,
      writeSpacingMs: 0,
    });
    await expect(restricted.listAudiences()).rejects.toThrow(
      /Full access/,
    );
  });

  test("fails loudly when contact pagination makes no progress", async () => {
    const stuckFetch: FetchLike = async () => ({
      status: 200,
      headers: { get: () => null },
      text: async () =>
        JSON.stringify({
          data: [{ id: "con_1", email: "a@example.com", unsubscribed: false }],
          has_more: true,
        }),
    });
    const stuck = new ResendClient({
      apiKey: "re_test",
      fetchImpl: stuckFetch,
      writeSpacingMs: 0,
    });
    await expect(stuck.listContacts("aud_1")).rejects.toThrow(
      ResendApiError,
    );
  });
});

describe("buildUsersAudienceContacts", () => {
  test("unions stack users and founders, deduped by email", () => {
    const merged = buildUsersAudienceContacts(
      [contact("both@example.com", "Stack"), contact("stack@example.com")],
      [
        {
          email: "both@example.com",
          firstName: "Stripe",
          sources: ["stripe"],
        },
        { email: "founder-only@example.com", sources: ["stripe"] },
      ],
    );
    expect(merged.map((c) => c.email).sort()).toEqual([
      "both@example.com",
      "founder-only@example.com",
      "stack@example.com",
    ]);
    // Equal name completeness: the Stack profile name wins.
    expect(
      merged.find((c) => c.email === "both@example.com")?.firstName,
    ).toBe("Stack");
  });
});
