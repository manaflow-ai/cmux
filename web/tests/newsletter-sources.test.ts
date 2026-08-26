import { describe, expect, test } from "bun:test";

// Source listing behavior: full pagination (no silent truncation), verified
// email filtering, founders-only filtering, and loud failure when a cursor
// stops advancing.

import type { FetchLike } from "../services/newsletter/resend-client";
import { listStackContacts } from "../services/newsletter/stack-source";
import { listFounderContacts } from "../services/newsletter/stripe-source";
import { fetchSourceJson } from "../services/newsletter/source-http";

type CannedResponse = { status?: number; body: unknown };

function fetchScript(
  script: (url: string, callIndex: number) => CannedResponse,
): { fetchImpl: FetchLike; calls: string[] } {
  const calls: string[] = [];
  const fetchImpl: FetchLike = async (url) => {
    const canned = script(url, calls.length);
    calls.push(url);
    return {
      status: canned.status ?? 200,
      headers: { get: () => null },
      text: async () => JSON.stringify(canned.body),
    };
  };
  return { fetchImpl, calls };
}

describe("listStackContacts", () => {
  test("pages through the whole user list and filters unverified emails", async () => {
    const { fetchImpl, calls } = fetchScript((url) => {
      // Restricted (not fully onboarded) users must be requested explicitly
      // or verified signups mid-onboarding would be silently omitted.
      expect(url).toContain("include_restricted=true");
      if (!url.includes("cursor=")) {
        return {
          body: {
            items: [
              {
                primary_email: "Ada@Example.com",
                primary_email_verified: true,
                server_metadata: { cmuxNewsletterOptIn: true },
                display_name: "Ada Lovelace",
              },
              {
                primary_email: "unverified@example.com",
                primary_email_verified: false,
              },
              { primary_email: null, primary_email_verified: false },
            ],
            pagination: { next_cursor: "cursor-2" },
          },
        };
      }
      expect(url).toContain("cursor=cursor-2");
      return {
        body: {
          items: [
            {
                primary_email: "grace@example.com",
                primary_email_verified: true,
                server_metadata: { cmuxNewsletterOptIn: true },
              display_name: "Grace",
            },
          ],
          pagination: { next_cursor: null },
        },
      };
    });

    const result = await listStackContacts({
      projectId: "proj",
      secretServerKey: "secret",
      fetchImpl,
    });

    expect(calls).toHaveLength(2);
    expect(result.totalUsers).toBe(4);
    expect(result.skippedMissingOrUnverifiedEmail).toBe(2);
    expect(result.skippedNotOptedIn).toBe(0);
    expect(result.contacts.map((c) => c.email).sort()).toEqual([
      "ada@example.com",
      "grace@example.com",
    ]);
    const ada = result.contacts.find((c) => c.email === "ada@example.com");
    expect(ada).toMatchObject({ firstName: "Ada", lastName: "Lovelace" });
  });

  test("fails loudly when the cursor stops advancing", async () => {
    const { fetchImpl } = fetchScript(() => ({
      body: {
        items: [
          { primary_email: "a@example.com", primary_email_verified: true },
        ],
        pagination: { next_cursor: "same-cursor" },
      },
    }));

    // First page: cursor null -> "same-cursor". Second page returns
    // "same-cursor" again, which must abort rather than loop or truncate.
    await expect(
      listStackContacts({
        projectId: "proj",
        secretServerKey: "secret",
        fetchImpl,
      }),
    ).rejects.toThrow(/no progress/);
  });

  test("requires explicit newsletter opt-in when requested", async () => {
    const { fetchImpl } = fetchScript(() => ({
      body: {
        items: [
          {
            primary_email: "not-opted-in@example.com",
            primary_email_verified: true,
          },
          {
            primary_email: "opted-in@example.com",
            primary_email_verified: true,
            server_metadata: { cmuxNewsletterOptIn: true },
          },
        ],
        pagination: { next_cursor: null },
      },
    }));
    const result = await listStackContacts({
      projectId: "proj",
      secretServerKey: "secret",
      fetchImpl,
      requireNewsletterOptIn: true,
    });
    expect(result.contacts.map((contact) => contact.email)).toEqual([
      "opted-in@example.com",
    ]);
    expect(result.skippedNotOptedIn).toBe(1);
  });

  test("surfaces permanent API errors with status, without retrying", async () => {
    const { fetchImpl, calls } = fetchScript(() => ({
      status: 401,
      body: { error: "unauthorized" },
    }));
    await expect(
      listStackContacts({
        projectId: "proj",
        secretServerKey: "bad",
        fetchImpl,
      }),
    ).rejects.toThrow(/401/);
    expect(calls).toHaveLength(1);
  });

  test("retries a transient failure before succeeding", async () => {
    const { fetchImpl, calls } = fetchScript((_url, callIndex) => {
      if (callIndex === 0) {
        return { status: 429, body: { error: "rate limited" } };
      }
      return {
        body: {
          items: [
            {
              primary_email: "ada@example.com",
              primary_email_verified: true,
            },
          ],
          pagination: { next_cursor: null },
        },
      };
    });

    const result = await listStackContacts({
      projectId: "proj",
      secretServerKey: "secret",
      fetchImpl,
    });

    expect(calls).toHaveLength(2);
    expect(result.contacts.map((c) => c.email)).toEqual(["ada@example.com"]);
  });

  test("bounds endlessly advancing cursors", async () => {
    const { fetchImpl } = fetchScript((url) => {
      const cursor = new URL(url).searchParams.get("cursor") ?? "first";
      return {
        body: {
          items: [
            {
              primary_email: `${cursor}@example.com`,
              primary_email_verified: true,
            },
          ],
          pagination: { next_cursor: `${cursor}-next` },
        },
      };
    });
    await expect(
      listStackContacts({
        projectId: "proj",
        secretServerKey: "secret",
        fetchImpl,
        maxPages: 2,
      }),
    ).rejects.toThrow(/page limit/);
  });
});

describe("fetchSourceJson", () => {
  test("retries transport failures without exposing the thrown detail", async () => {
    let calls = 0;
    const fetchImpl: FetchLike = async () => {
      calls += 1;
      if (calls === 1) throw new Error("secret socket URL");
      return {
        status: 200,
        headers: { get: () => null },
        text: async () => JSON.stringify({ ok: true }),
      };
    };
    await expect(
      fetchSourceJson({
        fetchImpl,
        url: "https://source.test/users",
        label: "source listing",
        backoffBaseMs: 0,
      }),
    ).resolves.toEqual({ ok: true });
    expect(calls).toBe(2);
  });

  test("honors a bounded Retry-After for rate limits", async () => {
    let calls = 0;
    const fetchImpl: FetchLike = async () => {
      calls += 1;
      return {
        status: 429,
        headers: { get: (name: string) => (name === "retry-after" ? "3600" : null) },
        text: async () => "{}",
      };
    };
    await expect(
      fetchSourceJson({
        fetchImpl,
        url: "https://source.test/users",
        label: "source listing",
        maxAttempts: 2,
        maxRetryAfterMs: 0,
        backoffBaseMs: 0,
      }),
    ).rejects.toThrow(/429/);
    expect(calls).toBe(2);
  });
});

describe("listFounderContacts", () => {
  const founderSession = (
    id: string,
    email: string | null,
    overrides: Record<string, unknown> = {},
  ) => ({
    id,
    status: "complete",
    payment_status: "paid",
    metadata: { founders_edition: "true" },
    customer_details: { email, name: "Fred Founder" },
    ...overrides,
  });

  test("pages with starting_after and keeps only completed founder purchases", async () => {
    const { fetchImpl, calls } = fetchScript((url) => {
      if (!url.includes("starting_after=")) {
        return {
          body: {
            data: [
              founderSession("cs_1", "fred@example.com"),
              // Not a founder purchase.
              {
                id: "cs_2",
                status: "complete",
                payment_status: "paid",
                metadata: { app: "cmux", plan: "pro" },
                customer_details: { email: "pro@example.com" },
              },
              // Founder metadata but abandoned checkout.
              founderSession("cs_3", "ghost@example.com", { status: "open", payment_status: "unpaid" }),
            ],
            has_more: true,
          },
        };
      }
      expect(url).toContain("starting_after=cs_3");
      return {
        body: {
          data: [
            // Duplicate purchase by the same founder email.
            founderSession("cs_4", "Fred@Example.com"),
            founderSession("cs_5", null),
            founderSession("cs_6", "freebie@example.com", {
              payment_status: "no_payment_required",
            }),
          ],
          has_more: false,
        },
      };
    });

    const result = await listFounderContacts({
      stripeSecretKey: "sk_test",
      fetchImpl,
    });

    expect(calls).toHaveLength(2);
    expect(result.totalSessions).toBe(6);
    expect(result.founderSessions).toBe(4);
    expect(result.skippedMissingEmail).toBe(1);
    expect(result.contacts.map((c) => c.email).sort()).toEqual([
      "fred@example.com",
      "freebie@example.com",
    ]);
  });

  test("fails loudly when pagination makes no progress", async () => {
    const { fetchImpl } = fetchScript(() => ({
      body: { data: [], has_more: true },
    }));
    await expect(
      listFounderContacts({ stripeSecretKey: "sk_test", fetchImpl }),
    ).rejects.toThrow(/no progress/);
  });

  test("surfaces API errors with status", async () => {
    const { fetchImpl } = fetchScript(() => ({
      status: 403,
      body: { error: { message: "forbidden" } },
    }));
    await expect(
      listFounderContacts({ stripeSecretKey: "sk_bad", fetchImpl }),
    ).rejects.toThrow(/403/);
  });
});
