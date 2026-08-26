import { describe, expect, test } from "bun:test";

// End-to-end sync behavior against a fake in-memory Resend API implementing
// the current data model (global contacts + segments + topics): resolution
// by name, dry-run purity (zero writes), apply writing exactly the plan,
// unsubscribe protection, contact pagination, and the restricted API key
// error.

import type { NewsletterContact } from "../services/newsletter/contacts";
import {
  ResendApiError,
  ResendClient,
  type FetchLike,
} from "../services/newsletter/resend-client";
import {
  FOUNDERS_SEGMENT_NAME,
  FOUNDERS_TOPIC,
  USERS_SEGMENT_NAME,
  USERS_TOPIC,
  buildUsersSegmentContacts,
  syncSegment,
} from "../services/newsletter/sync";

type FakeContact = {
  id: string;
  email: string;
  first_name?: string | null;
  last_name?: string | null;
  unsubscribed: boolean;
  properties?: Record<string, unknown> | null;
  segmentIds: Set<string>;
};

type FakeResend = {
  segments: { id: string; name: string }[];
  topics: { id: string; name: string; default_subscription?: string }[];
  contacts: FakeContact[];
  writes: string[];
  pageSize?: number;
  fetchImpl: FetchLike;
};

function fakeResend(options?: { pageSize?: number }): FakeResend {
  const state: FakeResend = {
    segments: [],
    topics: [],
    contacts: [],
    writes: [],
    pageSize: options?.pageSize,
    fetchImpl: undefined as unknown as FetchLike,
  };
  let nextId = 1;

  const paginate = <T extends { id: string }>(
    all: T[],
    searchParams: URLSearchParams,
  ) => {
    const pageSize = state.pageSize ?? 1000;
    const after = searchParams.get("after");
    const startIndex = after ? all.findIndex((c) => c.id === after) + 1 : 0;
    const page = all.slice(startIndex, startIndex + pageSize);
    return {
      data: page,
      has_more: startIndex + page.length < all.length,
    };
  };

  state.fetchImpl = async (url, init) => {
    const method = init?.method ?? "GET";
    const { pathname, searchParams } = new URL(url);
    const respond = (status: number, body: unknown) => ({
      status,
      headers: { get: () => null },
      text: async () => JSON.stringify(body),
    });
    const serializeContact = (c: FakeContact) => ({
      id: c.id,
      email: c.email,
      first_name: c.first_name ?? null,
      last_name: c.last_name ?? null,
      unsubscribed: c.unsubscribed,
      properties: c.properties ?? null,
    });

    if (method === "GET" && pathname === "/segments") {
      return respond(200, paginate(state.segments, searchParams));
    }
    if (method === "POST" && pathname === "/segments") {
      const { name } = JSON.parse(init?.body ?? "{}") as { name: string };
      const segment = { id: `seg_${nextId++}`, name };
      state.segments.push(segment);
      state.writes.push(`create-segment:${name}`);
      return respond(200, segment);
    }

    if (method === "GET" && pathname === "/topics") {
      return respond(200, paginate(state.topics, searchParams));
    }
    if (method === "POST" && pathname === "/topics") {
      const body = JSON.parse(init?.body ?? "{}") as {
        name: string;
        default_subscription?: string;
      };
      // Topics must be opt-in-by-default so contacts who never touched
      // preferences still receive the lane.
      expect(body.default_subscription).toBe("opt_in");
      const topic = {
        id: `top_${nextId++}`,
        name: body.name,
        default_subscription: body.default_subscription,
      };
      state.topics.push(topic);
      state.writes.push(`create-topic:${body.name}`);
      return respond(200, topic);
    }

    const segmentContacts = pathname.match(/^\/segments\/([^/]+)\/contacts$/);
    if (segmentContacts && method === "GET") {
      const segmentId = decodeURIComponent(segmentContacts[1]);
      if (!state.segments.some((s) => s.id === segmentId)) {
        return respond(404, { name: "not_found", message: "Segment not found" });
      }
      const pool = state.contacts.filter((c) => c.segmentIds.has(segmentId));
      const page = paginate(pool, searchParams);
      return respond(200, { ...page, data: page.data.map(serializeContact) });
    }
    if (method === "GET" && pathname === "/contacts") {
      const page = paginate(state.contacts, searchParams);
      return respond(200, { ...page, data: page.data.map(serializeContact) });
    }
    if (method === "POST" && pathname === "/contacts") {
      const body = JSON.parse(init?.body ?? "{}") as {
        email: string;
        first_name?: string;
        last_name?: string;
        properties?: Record<string, unknown>;
        unsubscribed?: boolean;
        topics?: unknown;
        segments?: { id: string }[];
      };
      // The sync must never send subscription state on create.
      expect("unsubscribed" in body).toBe(false);
      expect("topics" in body).toBe(false);
      // Segment assignments must be objects carrying the id, per the API.
      for (const segment of body.segments ?? []) {
        expect(typeof segment).toBe("object");
        expect(typeof segment.id).toBe("string");
      }
      const segmentIds = (body.segments ?? []).map((segment) => segment.id);
      const created: FakeContact = {
        id: `con_${nextId++}`,
        email: body.email,
        first_name: body.first_name ?? null,
        last_name: body.last_name ?? null,
        unsubscribed: false,
        properties: body.properties ?? null,
        segmentIds: new Set(segmentIds),
      };
      state.contacts.push(created);
      state.writes.push(`create-contact:${body.email}:[${segmentIds.join(",")}]`);
      return respond(200, { id: created.id });
    }

    const segmentAdd = pathname.match(/^\/contacts\/([^/]+)\/segments\/([^/]+)$/);
    if (segmentAdd && (method === "POST" || method === "DELETE")) {
      const key = decodeURIComponent(segmentAdd[1]);
      const segmentId = decodeURIComponent(segmentAdd[2]);
      const found = state.contacts.find(
        (c) => c.id === key || c.email === key,
      );
      if (!found) {
        return respond(404, { name: "not_found", message: "Contact not found" });
      }
      if (method === "POST") {
        found.segmentIds.add(segmentId);
        state.writes.push(`add-to-segment:${found.email}:${segmentId}`);
      } else {
        found.segmentIds.delete(segmentId);
        state.writes.push(`remove-from-segment:${found.email}:${segmentId}`);
      }
      return respond(200, { id: found.id });
    }

    const contactMatch = pathname.match(/^\/contacts\/([^/]+)$/);
    if (contactMatch) {
      const key = decodeURIComponent(contactMatch[1]);
      const found = state.contacts.find(
        (c) => c.id === key || c.email === key,
      );
      if (method === "GET") {
        return found
          ? respond(200, serializeContact(found))
          : respond(404, { name: "not_found", message: "Contact not found" });
      }
      if (method === "PATCH") {
        if (!found) {
          return respond(404, { name: "not_found", message: "Contact not found" });
        }
        const body = JSON.parse(init?.body ?? "{}") as {
          first_name?: string;
          last_name?: string;
          email?: string;
          properties?: Record<string, unknown>;
          unsubscribed?: boolean;
          topics?: unknown;
        };
        expect("unsubscribed" in body).toBe(false);
        expect("topics" in body).toBe(false);
        if (body.first_name) found.first_name = body.first_name;
        if (body.last_name) found.last_name = body.last_name;
        if (body.email) found.email = body.email;
        if (body.properties) {
          found.properties = { ...(found.properties ?? {}), ...body.properties };
        }
        state.writes.push(`patch-contact:${found.email}`);
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

async function listContactsOf(fake: FakeResend): Promise<
  Awaited<ReturnType<ResendClient["listContacts"]>>
> {
  return client(fake).listContacts();
}

describe("syncSegment", () => {
  test("dry run performs zero writes and reports the diff", async () => {
    const fake = fakeResend();
    fake.segments.push({ id: "seg_users", name: USERS_SEGMENT_NAME });
    fake.topics.push({
      id: "top_updates",
      name: USERS_TOPIC.name,
      default_subscription: "opt_in",
    });
    fake.contacts.push(
      {
        id: "con_1",
        email: "present@example.com",
        first_name: "P",
        unsubscribed: false,
        segmentIds: new Set(["seg_users"]),
      },
      {
        id: "con_2",
        email: "unsub@example.com",
        unsubscribed: true,
        segmentIds: new Set(),
      },
    );

    const summary = await syncSegment({
      client: client(fake),
      segmentName: USERS_SEGMENT_NAME,
      topic: USERS_TOPIC,
      desired: [
        contact("present@example.com"),
        contact("unsub@example.com"),
        contact("new@example.com", "New"),
      ],
      existingContacts: await listContactsOf(fake),
      apply: false,
    });

    expect(fake.writes).toEqual([]);
    expect(summary).toMatchObject({
      applied: false,
      segmentId: "seg_users",
      topicId: "top_updates",
      created: 1,
      alreadyPresent: 1,
      skippedUnsubscribed: 1,
    });
  });

  test("dry run against a missing segment reports without creating it", async () => {
    const fake = fakeResend();
    const summary = await syncSegment({
      client: client(fake),
      segmentName: FOUNDERS_SEGMENT_NAME,
      topic: FOUNDERS_TOPIC,
      desired: [contact("a@example.com")],
      existingContacts: [],
      apply: false,
    });
    expect(fake.writes).toEqual([]);
    expect(summary.segmentId).toBeNull();
    expect(summary.topicId).toBeNull();
    expect(summary.created).toBe(1);
  });

  test("apply creates contacts into the segment and never touches unsubscribed", async () => {
    const fake = fakeResend();
    fake.segments.push({ id: "seg_users", name: USERS_SEGMENT_NAME });
    fake.topics.push({
      id: "top_updates",
      name: USERS_TOPIC.name,
      default_subscription: "opt_in",
    });
    fake.contacts.push(
      {
        id: "con_2",
        email: "unsub@example.com",
        unsubscribed: true,
        segmentIds: new Set(),
      },
      {
        id: "con_3",
        email: "noname@example.com",
        unsubscribed: false,
        segmentIds: new Set(["seg_users"]),
      },
      {
        id: "con_4",
        email: "outside@example.com",
        first_name: "Otto",
        unsubscribed: false,
        segmentIds: new Set(),
      },
    );

    const summary = await syncSegment({
      client: client(fake),
      segmentName: USERS_SEGMENT_NAME,
      topic: USERS_TOPIC,
      desired: [
        contact("unsub@example.com", "Should NotWrite"),
        { email: "noname@example.com", firstName: "Nova", sources: ["stripe"] },
        contact("outside@example.com"),
        contact("new@example.com", "New"),
      ],
      existingContacts: await listContactsOf(fake),
      apply: true,
    });

    expect(fake.writes).toEqual([
      "create-contact:new@example.com:[seg_users]",
      "add-to-segment:outside@example.com:seg_users",
      "patch-contact:noname@example.com",
    ]);
    expect(summary).toMatchObject({
      applied: true,
      created: 1,
      addedToSegment: 1,
      nameBackfilled: 1,
      skippedUnsubscribed: 1,
    });
    const unsub = fake.contacts.find((c) => c.email === "unsub@example.com");
    expect(unsub?.unsubscribed).toBe(true);
    expect(unsub?.first_name ?? null).toBeNull();
    expect(unsub?.segmentIds.size).toBe(0);
  });

  test("apply creates a missing segment and topic by name", async () => {
    const fake = fakeResend();
    const summary = await syncSegment({
      client: client(fake),
      segmentName: FOUNDERS_SEGMENT_NAME,
      topic: FOUNDERS_TOPIC,
      desired: [contact("founder@example.com")],
      existingContacts: [],
      apply: true,
    });
    expect(summary.segmentCreated).toBe(true);
    expect(summary.topicCreated).toBe(true);
    expect(fake.writes.slice(0, 2)).toEqual([
      `create-segment:${FOUNDERS_SEGMENT_NAME}`,
      `create-topic:${FOUNDERS_TOPIC.name}`,
    ]);
    expect(fake.writes[2]).toStartWith("create-contact:founder@example.com");
  });

  test("reports stale segment members without removing them", async () => {
    const fake = fakeResend();
    fake.segments.push({ id: "seg_users", name: USERS_SEGMENT_NAME });
    fake.topics.push({
      id: "top_updates",
      name: USERS_TOPIC.name,
      default_subscription: "opt_in",
    });
    fake.contacts.push({
      id: "con_stale",
      email: "left@example.com",
      unsubscribed: false,
      segmentIds: new Set(["seg_users"]),
    });

    const summary = await syncSegment({
      client: client(fake),
      segmentName: USERS_SEGMENT_NAME,
      topic: USERS_TOPIC,
      // The member no longer appears in any source.
      desired: [],
      existingContacts: await listContactsOf(fake),
      apply: true,
    });

    // Additive by design: visibility, never removal.
    expect(summary.staleSegmentMembers).toBe(1);
    expect(fake.writes).toEqual([]);
    expect(
      fake.contacts.find((c) => c.email === "left@example.com")?.segmentIds
        .size,
    ).toBe(1);
  });

  test("removes only explicitly revoked contacts during an apply", async () => {
    const fake = fakeResend();
    fake.segments.push({ id: "seg_users", name: USERS_SEGMENT_NAME });
    fake.topics.push({
      id: "top_updates",
      name: USERS_TOPIC.name,
      default_subscription: "opt_in",
    });
    fake.contacts.push({
      id: "con_revoked",
      email: "revoked@example.com",
      unsubscribed: false,
      segmentIds: new Set(["seg_users"]),
    });

    const summary = await syncSegment({
      client: client(fake),
      segmentName: USERS_SEGMENT_NAME,
      topic: USERS_TOPIC,
      desired: [],
      existingContacts: await listContactsOf(fake),
      apply: true,
      revokedEmails: new Set(["revoked@example.com"]),
      pruneRevoked: true,
    });

    expect(summary.revokedFromSegment).toBe(1);
    expect(fake.writes).toEqual([
      "remove-from-segment:revoked@example.com:seg_users",
    ]);
    expect(
      fake.contacts.find((contact) => contact.email === "revoked@example.com")
        ?.segmentIds.size,
    ).toBe(0);
  });

  test("resolves a revocation through a migrated email alias", async () => {
    const fake = fakeResend();
    fake.segments.push({ id: "seg_founders", name: FOUNDERS_SEGMENT_NAME });
    fake.topics.push({
      id: "top_founders",
      name: FOUNDERS_TOPIC.name,
      default_subscription: "opt_in",
    });
    fake.contacts.push({
      id: "con_migrated",
      email: "new@example.com",
      unsubscribed: false,
      properties: { cmux_previous_emails: '["old@example.com"]' },
      segmentIds: new Set(["seg_founders"]),
    });

    const summary = await syncSegment({
      client: client(fake),
      segmentName: FOUNDERS_SEGMENT_NAME,
      topic: FOUNDERS_TOPIC,
      desired: [],
      existingContacts: await listContactsOf(fake),
      apply: false,
      revokedEmails: new Set(["old@example.com"]),
      pruneRevoked: false,
    });
    expect(summary.revokedFromSegment).toBe(1);
    expect(fake.writes).toEqual([]);
  });

  test("resolves a consent revocation by Stack identity after an email change", async () => {
    const fake = fakeResend();
    fake.segments.push({ id: "seg_users", name: USERS_SEGMENT_NAME });
    fake.topics.push({
      id: "top_updates",
      name: USERS_TOPIC.name,
      default_subscription: "opt_in",
    });
    fake.contacts.push({
      id: "con_rotated",
      email: "old-address@example.com",
      unsubscribed: false,
      properties: { cmux_stack_user_id: "stack-rotated" },
      segmentIds: new Set(["seg_users"]),
    });

    const summary = await syncSegment({
      client: client(fake),
      segmentName: USERS_SEGMENT_NAME,
      topic: USERS_TOPIC,
      desired: [],
      existingContacts: await listContactsOf(fake),
      apply: false,
      revokedStackUserIds: new Set(["stack-rotated"]),
    });
    expect(summary.revokedFromSegment).toBe(1);
  });

  test("does not write even a revocation delete for a globally unsubscribed contact", async () => {
    const fake = fakeResend();
    fake.segments.push({ id: "seg_founders", name: FOUNDERS_SEGMENT_NAME });
    fake.topics.push({
      id: "top_founders",
      name: FOUNDERS_TOPIC.name,
      default_subscription: "opt_in",
    });
    fake.contacts.push({
      id: "con_unsub_revoked",
      email: "unsub-revoked@example.com",
      unsubscribed: true,
      segmentIds: new Set(["seg_founders"]),
    });

    await syncSegment({
      client: client(fake),
      segmentName: FOUNDERS_SEGMENT_NAME,
      topic: FOUNDERS_TOPIC,
      desired: [],
      existingContacts: await listContactsOf(fake),
      apply: true,
      revokedEmails: new Set(["unsub-revoked@example.com"]),
      pruneRevoked: true,
    });
    expect(fake.writes).toEqual([]);
  });

  test("fails closed on a same-name topic whose immutable default is opt_out", async () => {
    const fake = fakeResend();
    fake.segments.push({ id: "seg_users", name: USERS_SEGMENT_NAME });
    fake.topics.push({
      id: "top_updates",
      name: USERS_TOPIC.name,
      default_subscription: "opt_out",
    });
    await expect(
      syncSegment({
        client: client(fake),
        segmentName: USERS_SEGMENT_NAME,
        topic: USERS_TOPIC,
        desired: [contact("a@example.com")],
        existingContacts: [],
        apply: true,
      }),
    ).rejects.toThrow(/opt_in/);
    // Fail-closed means no writes happened either.
    expect(fake.writes).toEqual([]);
  });

  test("ambiguous segment names fail loudly", async () => {
    const fake = fakeResend();
    fake.segments.push(
      { id: "seg_1", name: USERS_SEGMENT_NAME },
      { id: "seg_2", name: USERS_SEGMENT_NAME },
    );
    fake.topics.push({
      id: "top_updates",
      name: USERS_TOPIC.name,
      default_subscription: "opt_in",
    });
    await expect(
      syncSegment({
        client: client(fake),
        segmentName: USERS_SEGMENT_NAME,
        topic: USERS_TOPIC,
        desired: [],
        existingContacts: [],
        apply: false,
      }),
    ).rejects.toThrow(/ambiguous/);
  });

  test("reads the full membership across pages before planning", async () => {
    const fake = fakeResend({ pageSize: 2 });
    fake.segments.push({ id: "seg_users", name: USERS_SEGMENT_NAME });
    fake.topics.push({
      id: "top_updates",
      name: USERS_TOPIC.name,
      default_subscription: "opt_in",
    });
    for (let i = 0; i < 5; i += 1) {
      fake.contacts.push({
        id: `con_${i}`,
        email: `existing${i}@example.com`,
        unsubscribed: false,
        segmentIds: new Set(["seg_users"]),
      });
    }

    const summary = await syncSegment({
      client: client(fake),
      segmentName: USERS_SEGMENT_NAME,
      topic: USERS_TOPIC,
      // All five already exist and are members; a truncated read would plan
      // spurious creates or segment adds.
      desired: Array.from({ length: 5 }, (_, i) =>
        contact(`existing${i}@example.com`),
      ),
      existingContacts: await listContactsOf(fake),
      apply: true,
    });

    expect(summary.existingSegmentMembers).toBe(5);
    expect(summary.created).toBe(0);
    expect(summary.addedToSegment).toBe(0);
    expect(fake.writes).toEqual([]);
  });

  test("rechecks unsubscribe state before each apply mutation", async () => {
    const contactState = {
      id: "con_1",
      email: "race@example.com",
      first_name: null,
      last_name: null,
      unsubscribed: false,
    };
    const writes: string[] = [];
    let lookupCount = 0;
    const fakeClient = {
      async findSegmentByName() {
        return { id: "seg_users", name: USERS_SEGMENT_NAME };
      },
      async findTopicByName() {
        return {
          id: "top_updates",
          name: USERS_TOPIC.name,
          defaultSubscription: "opt_in",
        };
      },
      async listSegmentContacts() {
        return [];
      },
      async getContactByEmail() {
        lookupCount += 1;
        if (lookupCount > 0) contactState.unsubscribed = true;
        return contactState;
      },
      async addContactToSegment() {
        writes.push("add");
      },
      async updateContactName() {
        writes.push("patch");
      },
      async createContact() {
        writes.push("create");
      },
    } as unknown as ResendClient;

    const summary = await syncSegment({
      client: fakeClient,
      segmentName: USERS_SEGMENT_NAME,
      topic: USERS_TOPIC,
      desired: [contact("race@example.com", "Race")],
      existingContacts: [
        {
          id: "con_1",
          email: "race@example.com",
          unsubscribed: false,
        },
      ],
      apply: true,
    });

    expect(writes).toEqual([]);
    expect(summary.created).toBe(0);
    expect(summary.addedToSegment).toBe(0);
  });

  test("blocks a Stack email change instead of creating a new subscribed contact", async () => {
    const fake = fakeResend();
    fake.segments.push({ id: "seg_users", name: USERS_SEGMENT_NAME });
    fake.topics.push({
      id: "top_updates",
      name: USERS_TOPIC.name,
      default_subscription: "opt_in",
    });
    fake.contacts.push({
      id: "con_stack",
      email: "old@example.com",
      unsubscribed: false,
      properties: { cmux_stack_user_id: "stack-1" },
      segmentIds: new Set(["seg_users"]),
    });

    const summary = await syncSegment({
      client: client(fake),
      segmentName: USERS_SEGMENT_NAME,
      topic: USERS_TOPIC,
      desired: [
        {
          email: "new@example.com",
          stackUserId: "stack-1",
          sources: ["stack"],
        },
      ],
      existingContacts: await listContactsOf(fake),
      apply: true,
    });

    expect(summary.blockedIdentityChanges).toBe(1);
    expect(summary.identityMembershipRemoved).toBe(1);
    expect(summary.created).toBe(0);
    expect(fake.writes).toEqual([
      "remove-from-segment:old@example.com:seg_users",
    ]);
    expect(fake.contacts[0].email).toBe("old@example.com");
    expect(fake.contacts[0].unsubscribed).toBe(false);
    expect(fake.contacts[0].segmentIds.has("seg_users")).toBe(false);
  });

  test("backfills the Stack identity property on an existing contact", async () => {
    const fake = fakeResend();
    fake.segments.push({ id: "seg_users", name: USERS_SEGMENT_NAME });
    fake.topics.push({
      id: "top_updates",
      name: USERS_TOPIC.name,
      default_subscription: "opt_in",
    });
    fake.contacts.push({
      id: "con_existing",
      email: "existing@example.com",
      unsubscribed: false,
      segmentIds: new Set(["seg_users"]),
    });

    await syncSegment({
      client: client(fake),
      segmentName: USERS_SEGMENT_NAME,
      topic: USERS_TOPIC,
      desired: [
        {
          email: "existing@example.com",
          stackUserId: "stack-existing",
          sources: ["stack"],
        },
      ],
      existingContacts: await listContactsOf(fake),
      apply: true,
    });
    expect(fake.contacts[0].properties).toMatchObject({
      cmux_stack_user_id: "stack-existing",
    });
    expect(fake.writes).toContain("patch-contact:existing@example.com");
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
    await expect(restricted.listSegments()).rejects.toThrow(/Full access/);
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
    await expect(stuck.listContacts()).rejects.toThrow(ResendApiError);
  });

  test("errors from contact endpoints never contain the email address", async () => {
    const failingFetch: FetchLike = async () => ({
      status: 500,
      headers: { get: () => null },
      text: async () =>
        JSON.stringify({ name: "server_error", message: "boom" }),
    });
    const failing = new ResendClient({
      apiKey: "re_test",
      fetchImpl: failingFetch,
      writeSpacingMs: 0,
    });
    try {
      await failing.getContactByEmail("secret-person@example.com");
      throw new Error("expected a ResendApiError");
    } catch (error) {
      expect(error).toBeInstanceOf(ResendApiError);
      expect((error as Error).message).not.toContain("secret-person");
      expect((error as Error).message).toContain("/contacts/<email>");
    }
  });

  test("retries a transient Resend transport failure", async () => {
    let calls = 0;
    const fetchImpl: FetchLike = async () => {
      calls += 1;
      if (calls === 1) throw new Error("secret socket details");
      return {
        status: 200,
        headers: { get: () => null },
        text: async () => JSON.stringify({ data: [], has_more: false }),
      };
    };
    const client = new ResendClient({
      apiKey: "re_test",
      fetchImpl,
      writeSpacingMs: 0,
    });
    await expect(client.listSegments()).resolves.toEqual([]);
    expect(calls).toBe(2);
  });

  test("hydrates and unwraps contact properties from point reads", async () => {
    const fetchImpl: FetchLike = async (url) => {
      const pathname = new URL(url).pathname;
      if (pathname === "/contacts") {
        return {
          status: 200,
          headers: { get: () => null },
          text: async () =>
            JSON.stringify({
              data: [
                {
                  id: "con_props",
                  email: "props@example.com",
                  unsubscribed: false,
                },
              ],
              has_more: false,
            }),
        };
      }
      return {
        status: 200,
        headers: { get: () => null },
        text: async () =>
          JSON.stringify({
            id: "con_props",
            email: "props@example.com",
            unsubscribed: false,
            properties: {
              cmux_stack_user_id: { type: "string", value: "stack-1" },
              cmux_previous_emails: {
                type: "string",
                value: '["old@example.com"]',
              },
            },
          }),
      };
    };
    const contacts = await new ResendClient({
      apiKey: "re_props",
      fetchImpl,
      writeSpacingMs: 0,
    }).listContacts();
    expect(contacts[0].properties).toEqual({
      cmux_stack_user_id: "stack-1",
      cmux_previous_emails: '["old@example.com"]',
    });
  });

  test("a cancel signal stops in-flight requests and pending backoff", async () => {
    const abort = new AbortController();
    let calls = 0;
    const rateLimitedFetch: FetchLike = async () => {
      calls += 1;
      return {
        status: 429,
        headers: { get: (name: string) => (name === "retry-after" ? "4" : null) },
        text: async () => JSON.stringify({ message: "rate limited" }),
      };
    };
    const cancellable = new ResendClient({
      apiKey: "re_test",
      fetchImpl: rateLimitedFetch,
      writeSpacingMs: 0,
      cancelSignal: abort.signal,
    });
    const pending = cancellable.listSegments();
    // Cancel while the client is sleeping in 429 backoff; without signal
    // threading this would keep retrying for several more seconds.
    setTimeout(() => abort.abort(), 20);
    await expect(pending).rejects.toThrow(/cancelled/);
    expect(calls).toBe(1);
  });

  test("aborts a stalled request at the configured timeout", async () => {
    const neverFetch: FetchLike = (_url, init) =>
      new Promise((_, reject) => {
        init?.signal?.addEventListener("abort", () =>
          reject(new Error("aborted")),
        );
      });
    const bounded = new ResendClient({
      apiKey: "re_test",
      fetchImpl: neverFetch,
      writeSpacingMs: 0,
      requestTimeoutMs: 25,
    });
    await expect(bounded.listSegments()).rejects.toThrow(/timed out/);
  });

  test("caps a hostile Retry-After so retries stay bounded", async () => {
    let calls = 0;
    const rateLimitedFetch: FetchLike = async () => {
      calls += 1;
      return {
        status: 429,
        headers: { get: (name: string) => (name === "retry-after" ? "3600" : null) },
        text: async () => JSON.stringify({ message: "rate limited" }),
      };
    };
    const limited = new ResendClient({
      apiKey: "re_test",
      fetchImpl: rateLimitedFetch,
      writeSpacingMs: 0,
      maxRetryAfterMs: 10,
    });
    // The hostile 3600s Retry-After is capped by maxRetryAfterMs; if the
    // cap were ignored this test would blow the per-test timeout (4 waits
    // of an hour each) instead of completing in milliseconds.
    await expect(limited.listSegments()).rejects.toThrow(/429/);
    expect(calls).toBe(5);
  });
});

describe("buildUsersSegmentContacts", () => {
  test("unions stack users and founders, deduped by email", () => {
    const merged = buildUsersSegmentContacts(
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
