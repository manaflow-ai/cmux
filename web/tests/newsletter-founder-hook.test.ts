import { describe, expect, test } from "bun:test";

// Purchase-time audience upsert used by /api/stripe/founders-welcome: adds a
// founder to both audiences, never resurrects an unsubscribed contact, and
// only backfills missing names.

import { upsertFounderIntoAudiences } from "../services/newsletter/founder-hook";
import type {
  ResendClient,
  ResendContact,
} from "../services/newsletter/resend-client";
import {
  FOUNDERS_AUDIENCE_NAME,
  USERS_AUDIENCE_NAME,
} from "../services/newsletter/sync";

type FakeAudience = {
  id: string;
  name: string;
  contacts: ResendContact[];
};

function fakeClient(audiences: FakeAudience[]): {
  client: ResendClient;
  writes: string[];
} {
  const writes: string[] = [];
  const client = {
    async findAudienceByName(name: string) {
      const found = audiences.find((a) => a.name === name);
      return found ? { id: found.id, name: found.name } : null;
    },
    async getContactByEmail(audienceId: string, email: string) {
      const audience = audiences.find((a) => a.id === audienceId);
      return (
        audience?.contacts.find((c) => c.email === email) ?? null
      );
    },
    async createContact(
      audienceId: string,
      contact: { email: string; firstName?: string; lastName?: string },
    ) {
      writes.push(`create:${audienceId}:${contact.email}`);
    },
    async updateContactName(audienceId: string, contactId: string) {
      writes.push(`patch:${audienceId}:${contactId}`);
    },
  } as unknown as ResendClient;
  return { client, writes };
}

const bothAudiences = (): FakeAudience[] => [
  { id: "aud_users", name: USERS_AUDIENCE_NAME, contacts: [] },
  { id: "aud_founders", name: FOUNDERS_AUDIENCE_NAME, contacts: [] },
];

describe("upsertFounderIntoAudiences", () => {
  test("adds a new founder to both audiences with a split name", async () => {
    const audiences = bothAudiences();
    const { client, writes } = fakeClient(audiences);
    const results = await upsertFounderIntoAudiences({
      client,
      email: "Fred@Example.com",
      customerName: "Fred Founder",
    });
    expect(writes).toEqual([
      "create:aud_users:fred@example.com",
      "create:aud_founders:fred@example.com",
    ]);
    expect(results.map((r) => r.outcome)).toEqual(["created", "created"]);
  });

  test("unsubscribed in one audience does not block the other", async () => {
    const audiences = bothAudiences();
    audiences[0].contacts.push({
      id: "con_1",
      email: "fred@example.com",
      unsubscribed: true,
    });
    const { client, writes } = fakeClient(audiences);
    const results = await upsertFounderIntoAudiences({
      client,
      email: "fred@example.com",
      customerName: "Fred Founder",
    });
    expect(writes).toEqual(["create:aud_founders:fred@example.com"]);
    expect(results).toEqual([
      {
        audienceName: USERS_AUDIENCE_NAME,
        outcome: "skipped_unsubscribed",
      },
      { audienceName: FOUNDERS_AUDIENCE_NAME, outcome: "created" },
    ]);
  });

  test("existing subscribed contact with a name is left untouched", async () => {
    const audiences = bothAudiences();
    for (const audience of audiences) {
      audience.contacts.push({
        id: "con_1",
        email: "fred@example.com",
        first_name: "Fred",
        last_name: "Founder",
        unsubscribed: false,
      });
    }
    const { client, writes } = fakeClient(audiences);
    const results = await upsertFounderIntoAudiences({
      client,
      email: "fred@example.com",
      customerName: "Different Name",
    });
    expect(writes).toEqual([]);
    expect(results.map((r) => r.outcome)).toEqual([
      "already_present",
      "already_present",
    ]);
  });

  test("missing audiences are reported, not created, by the webhook path", async () => {
    const { client, writes } = fakeClient([]);
    const results = await upsertFounderIntoAudiences({
      client,
      email: "fred@example.com",
    });
    expect(writes).toEqual([]);
    expect(results.map((r) => r.outcome)).toEqual([
      "skipped_missing_audience",
      "skipped_missing_audience",
    ]);
  });

  test("rejects an unusable email instead of writing garbage", async () => {
    const { client } = fakeClient(bothAudiences());
    await expect(
      upsertFounderIntoAudiences({ client, email: "   " }),
    ).rejects.toThrow(/valid email/);
  });
});
