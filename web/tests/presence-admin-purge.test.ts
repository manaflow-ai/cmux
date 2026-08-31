import { afterEach, beforeEach, describe, expect, mock, test } from "bun:test";

import {
  buildPresenceAdminPurgeRequest,
  purgePresenceForDeletedAccount,
  schedulePresenceAccountPurge,
} from "../services/presence/adminPurge";

const consoleWarn = mock(() => {});
const originalConsoleWarn = console.warn;

beforeEach(() => {
  consoleWarn.mockClear();
  console.warn = consoleWarn as typeof console.warn;
});

afterEach(() => {
  console.warn = originalConsoleWarn;
});

describe("presence admin purge", () => {
  test("builds a backend-only worker purge request", async () => {
    const purge = buildPresenceAdminPurgeRequest(
      { teamId: "team-1", userId: "user-1" },
      {
        baseURL: "https://presence.example.test/dev",
        purgeSecret: "s".repeat(64),
      },
    );

    expect(purge?.url).toBe("https://presence.example.test/v1/admin/purge-user");
    expect(purge?.method).toBe("POST");
    expect(purge?.headers.get("authorization")).toBe(`Bearer ${"s".repeat(64)}`);
    expect(await purge?.json()).toEqual({ teamId: "team-1", userId: "user-1" });
  });

  test("builds nothing while the worker or secret is unconfigured", () => {
    expect(buildPresenceAdminPurgeRequest(
      { teamId: "team-1", userId: "user-1" },
      { baseURL: "https://presence.example.test" },
    )).toBeNull();
    expect(buildPresenceAdminPurgeRequest(
      { teamId: "team-1", userId: "user-1" },
      { purgeSecret: "s".repeat(64) },
    )).toBeNull();
  });

  test("purges once per unique deletion team id", async () => {
    const purged: Array<{ url: string; body: unknown }> = [];
    await purgePresenceForDeletedAccount(
      { userId: "user-1", teamIds: ["user-1", "team-a", "user-1"] },
      {
        buildRequest: (input) => buildPresenceAdminPurgeRequest(input, {
          baseURL: "https://presence.example.test",
          purgeSecret: "s".repeat(64),
        }),
        fetchResponse: (async (request: Request) => {
          purged.push({ url: request.url, body: await request.json() });
          return new Response(JSON.stringify({ ok: true, devicesPurged: 1 }), { status: 200 });
        }) as typeof fetch,
      },
    );

    expect(purged).toEqual([
      {
        url: "https://presence.example.test/v1/admin/purge-user",
        body: { teamId: "user-1", userId: "user-1" },
      },
      {
        url: "https://presence.example.test/v1/admin/purge-user",
        body: { teamId: "team-a", userId: "user-1" },
      },
    ]);
    expect(consoleWarn).not.toHaveBeenCalled();
  });

  test("one team's failure is logged and does not skip the rest or throw", async () => {
    const attempted: string[] = [];
    await purgePresenceForDeletedAccount(
      { userId: "user-1", teamIds: ["team-down", "team-rejects", "team-up"] },
      {
        buildRequest: (input) => buildPresenceAdminPurgeRequest(input, {
          baseURL: "https://presence.example.test",
          purgeSecret: "s".repeat(64),
        }),
        fetchResponse: (async (request: Request) => {
          const { teamId } = await request.json() as { teamId: string };
          attempted.push(teamId);
          if (teamId === "team-down") throw new Error("connect ECONNREFUSED");
          if (teamId === "team-rejects") return new Response("nope", { status: 503 });
          return new Response(JSON.stringify({ ok: true, devicesPurged: 0 }), { status: 200 });
        }) as typeof fetch,
      },
    );

    expect(attempted).toEqual(["team-down", "team-rejects", "team-up"]);
    expect(consoleWarn).toHaveBeenCalledTimes(2);
  });

  test("resolves quietly when the presence worker is unconfigured", async () => {
    let fetched = 0;
    await purgePresenceForDeletedAccount(
      { userId: "user-1", teamIds: ["team-a"] },
      {
        buildRequest: () => null,
        fetchResponse: (async () => {
          fetched += 1;
          return new Response(null, { status: 200 });
        }) as typeof fetch,
      },
    );

    expect(fetched).toBe(0);
    expect(consoleWarn).not.toHaveBeenCalled();
  });

  test("scheduling outside a request scope neither throws nor fetches", () => {
    // `after` throws outside a Next request; the fallback runs fire-and-forget
    // and (with no worker configured in the test env) purges nothing.
    expect(() => schedulePresenceAccountPurge({ userId: "user-1", teamIds: ["team-a"] }))
      .not.toThrow();
  });
});
