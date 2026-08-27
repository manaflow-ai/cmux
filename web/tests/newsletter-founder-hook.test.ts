import { describe, expect, test } from "bun:test";

// Purchase-time segment upsert used by /api/stripe/founders-welcome: adds a
// founder to both cmux segments, never writes anything for a globally
// unsubscribed contact, only backfills missing names, and its deadline
// helper actually bounds a stalled upsert.

import {
  upsertFounderIntoSegments,
  withDeadline,
} from "../services/newsletter/founder-hook";
import type {
  ResendClient,
  ResendContact,
} from "../services/newsletter/resend-client";
import { ResendApiError } from "../services/newsletter/resend-client";
import {
  FOUNDERS_SEGMENT_NAME,
  USERS_SEGMENT_NAME,
} from "../services/newsletter/sync";

type FakeState = {
  segments: { id: string; name: string }[];
  contacts: ResendContact[];
};

function fakeClient(state: FakeState): {
  client: ResendClient;
  writes: string[];
} {
  const writes: string[] = [];
  const client = {
    async listSegments() {
      return state.segments;
    },
    async getContactByEmail(email: string) {
      return state.contacts.find((c) => c.email === email) ?? null;
    },
    async createContact(contact: {
      email: string;
      firstName?: string;
      lastName?: string;
      segmentIds?: string[];
    }) {
      writes.push(
        `create:${contact.email}:[${(contact.segmentIds ?? []).join(",")}]`,
      );
    },
    async updateContactName(contactId: string) {
      writes.push(`patch:${contactId}`);
    },
    async addContactToSegment(contactId: string, segmentId: string) {
      writes.push(`add:${contactId}:${segmentId}`);
    },
  } as unknown as ResendClient;
  return { client, writes };
}

const bothSegments = (): FakeState => ({
  segments: [
    { id: "seg_users", name: USERS_SEGMENT_NAME },
    { id: "seg_founders", name: FOUNDERS_SEGMENT_NAME },
  ],
  contacts: [],
});

describe("upsertFounderIntoSegments", () => {
  test("creates a missing contact directly into both segments with a split name", async () => {
    const state = bothSegments();
    const { client, writes } = fakeClient(state);
    const results = await upsertFounderIntoSegments({
      client,
      email: "Fred@Example.com",
      customerName: "Fred Founder",
    });
    expect(writes).toEqual(["create:fred@example.com:[seg_users,seg_founders]"]);
    expect(results.map((r) => r.outcome)).toEqual(["created", "created"]);
  });

  test("a globally unsubscribed contact gets zero writes in every segment", async () => {
    const state = bothSegments();
    state.contacts.push({
      id: "con_1",
      email: "fred@example.com",
      unsubscribed: true,
    });
    const { client, writes } = fakeClient(state);
    const results = await upsertFounderIntoSegments({
      client,
      email: "fred@example.com",
      customerName: "Fred Founder",
    });
    expect(writes).toEqual([]);
    expect(results).toEqual([
      { segmentName: USERS_SEGMENT_NAME, outcome: "skipped_unsubscribed" },
      { segmentName: FOUNDERS_SEGMENT_NAME, outcome: "skipped_unsubscribed" },
    ]);
  });

  test("an existing subscribed contact is added to both segments without name overwrite", async () => {
    const state = bothSegments();
    state.contacts.push({
      id: "con_1",
      email: "fred@example.com",
      first_name: "Fred",
      last_name: "Founder",
      unsubscribed: false,
    });
    const { client, writes } = fakeClient(state);
    const results = await upsertFounderIntoSegments({
      client,
      email: "fred@example.com",
      customerName: "Different Name",
    });
    expect(writes).toEqual([
      "add:con_1:seg_users",
      "add:con_1:seg_founders",
    ]);
    expect(results.map((r) => r.outcome)).toEqual([
      "membership_ensured",
      "membership_ensured",
    ]);
  });

  test("backfills a missing name once on the global contact", async () => {
    const state = bothSegments();
    state.contacts.push({
      id: "con_1",
      email: "fred@example.com",
      unsubscribed: false,
    });
    const { client, writes } = fakeClient(state);
    const results = await upsertFounderIntoSegments({
      client,
      email: "fred@example.com",
      customerName: "Fred Founder",
    });
    expect(writes).toEqual([
      "patch:con_1",
      "add:con_1:seg_users",
      "add:con_1:seg_founders",
    ]);
    expect(results.map((r) => r.outcome)).toEqual([
      "name_backfilled",
      "name_backfilled",
    ]);
  });

  test("missing segments are reported, not created, by the webhook path", async () => {
    const { client, writes } = fakeClient({ segments: [], contacts: [] });
    const results = await upsertFounderIntoSegments({
      client,
      email: "fred@example.com",
    });
    expect(writes).toEqual([]);
    expect(results.map((r) => r.outcome)).toEqual([
      "skipped_missing_segment",
      "skipped_missing_segment",
    ]);
  });

  test("recovers when another delivery wins the contact-create race", async () => {
    const state = bothSegments();
    const existing: ResendContact = {
      id: "con_raced",
      email: "fred@example.com",
      unsubscribed: false,
    };
    let lookups = 0;
    const writes: string[] = [];
    const client = {
      async listSegments() {
        return state.segments;
      },
      async getContactByEmail() {
        lookups += 1;
        return lookups <= 2 ? null : existing;
      },
      async createContact() {
        writes.push("create");
        throw new ResendApiError("duplicate", 409, "contact_already_exists");
      },
      async updateContactName() {
        writes.push("patch");
      },
      async addContactToSegment(contactId: string, segmentId: string) {
        writes.push(`add:${contactId}:${segmentId}`);
      },
    } as unknown as ResendClient;

    const results = await upsertFounderIntoSegments({
      client,
      email: "fred@example.com",
    });
    expect(writes).toEqual([
      "create",
      "add:con_raced:seg_users",
      "add:con_raced:seg_founders",
    ]);
    expect(results.map((result) => result.outcome)).toEqual([
      "membership_ensured",
      "membership_ensured",
    ]);
  });

  test("rechecks unsubscribe state before mutating an existing contact", async () => {
    const state = bothSegments();
    const subscribed: ResendContact = {
      id: "con_1",
      email: "fred@example.com",
      unsubscribed: false,
    };
    const unsubscribed = { ...subscribed, unsubscribed: true };
    let lookups = 0;
    const writes: string[] = [];
    const client = {
      async listSegments() {
        return state.segments;
      },
      async getContactByEmail() {
        lookups += 1;
        return lookups === 1 ? subscribed : unsubscribed;
      },
      async addContactToSegment() {
        writes.push("add");
      },
    } as unknown as ResendClient;

    const results = await upsertFounderIntoSegments({
      client,
      email: "fred@example.com",
    });
    expect(writes).toEqual([]);
    expect(results).toEqual([
      { segmentName: USERS_SEGMENT_NAME, outcome: "skipped_unsubscribed" },
      {
        segmentName: FOUNDERS_SEGMENT_NAME,
        outcome: "skipped_unsubscribed",
      },
    ]);
  });

  test("keeps attempting later segments when one add fails", async () => {
    const state = bothSegments();
    const existing: ResendContact = {
      id: "con_1",
      email: "fred@example.com",
      unsubscribed: false,
    };
    let addCalls = 0;
    const client = {
      async listSegments() {
        return state.segments;
      },
      async getContactByEmail() {
        return existing;
      },
      async addContactToSegment() {
        addCalls += 1;
        if (addCalls === 1) throw new Error("temporary provider failure");
      },
    } as unknown as ResendClient;

    const results = await upsertFounderIntoSegments({
      client,
      email: "fred@example.com",
    });
    expect(results.map((result) => result.outcome)).toEqual([
      "failed",
      "membership_ensured",
    ]);
  });

  test("rejects an unusable email instead of writing garbage", async () => {
    const { client } = fakeClient(bothSegments());
    await expect(
      upsertFounderIntoSegments({ client, email: "   " }),
    ).rejects.toThrow(/valid email/);
  });
});

describe("withDeadline", () => {
  test("returns the work's result when it beats the deadline", async () => {
    await expect(withDeadline(Promise.resolve("ok"), 1000)).resolves.toBe(
      "ok",
    );
  });

  test("rejects when the work stalls past the deadline", async () => {
    const stalled = new Promise<never>(() => {});
    await expect(withDeadline(stalled, 0)).rejects.toThrow(/deadline/);
  });

  test("aborts the provided controller when the deadline fires", async () => {
    const abort = new AbortController();
    const stalled = new Promise<never>(() => {});
    await expect(withDeadline(stalled, 0, abort)).rejects.toThrow(
      /deadline/,
    );
    expect(abort.signal.aborted).toBe(true);
  });

  test("does not abort the controller when the work wins", async () => {
    const abort = new AbortController();
    await expect(
      withDeadline(Promise.resolve("ok"), 1000, abort),
    ).resolves.toBe("ok");
    expect(abort.signal.aborted).toBe(false);
  });
});
