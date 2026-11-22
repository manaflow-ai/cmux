import { describe, expect, test } from "bun:test";
import { createHexclaveServerApi, HexclaveApiError } from "../services/auth/hexclave/serverApi";
import { serverTeam, serverUser, TEAM_ID, teamPermission, USER_ID } from "./helpers/hexclave-fixtures";

type Reply = { status?: number; body?: unknown; headers?: Record<string, string> };

function api(replies: Reply[], options: { retries?: number } = {}) {
  const requests: { url: URL; headers: Headers }[] = [];
  const slept: number[] = [];
  const source = createHexclaveServerApi({
    projectId: "project-1",
    secretServerKey: "server-key",
    baseURL: "https://hexclave.test",
    retries: options.retries,
    sleep: async (ms) => { slept.push(ms); },
    fetch: (async (input: URL, init?: RequestInit) => {
      requests.push({ url: new URL(input), headers: new Headers(init?.headers) });
      const reply = replies.shift() ?? { status: 500 };
      if (reply.status === -1) throw new DOMException("The operation timed out.", "TimeoutError");
      return new Response(reply.body === undefined ? null : JSON.stringify(reply.body), {
        status: reply.status ?? 200,
        headers: reply.headers,
      });
    }) as typeof fetch,
  });
  return { source, requests, slept };
}

describe("Hexclave server API", () => {
  test("reads a user with server credentials and validates it", async () => {
    const { source, requests } = api([{ body: serverUser() }]);
    expect(await source.getUser(USER_ID)).toEqual(serverUser());
    expect(requests[0]!.url.toString()).toBe(`https://hexclave.test/api/v1/users/${USER_ID}`);
    expect(requests[0]!.headers.get("x-hexclave-access-type")).toBe("server");
    expect(requests[0]!.headers.get("x-hexclave-secret-server-key")).toBe("server-key");
  });

  test("a known not-found answer is null; any other 404 is an error", async () => {
    expect(await api([{ status: 404, headers: { "x-hexclave-known-error": "USER_NOT_FOUND" } }]).source.getUser(USER_ID)).toBeNull();
    expect(await api([{ status: 404, headers: { "x-stack-known-error": "TEAM_NOT_FOUND" } }]).source.getTeam(TEAM_ID)).toBeNull();
    await expect(api([{ status: 404 }]).source.getUser(USER_ID)).rejects.toBeInstanceOf(HexclaveApiError);
  });

  test("a response that fails Hexclave's own schema is an error, never a partial row", async () => {
    await expect(api([{ body: { ...serverUser(), is_anonymous: "no" } }]).source.getUser(USER_ID)).rejects.toThrow("schema validation");
    await expect(api([{ body: { items: [{ id: "team_member", user_id: USER_ID }] } }]).source.listUserTeamPermissions(USER_ID))
      .rejects.toThrow("schema validation");
  });

  test("a paged answer from a list read as complete is an error, never a truncated list", async () => {
    const paged = { items: [teamPermission()], is_paginated: true, pagination: { next_cursor: USER_ID } };
    await expect(api([{ body: paged }]).source.listUserTeamPermissions(USER_ID)).rejects.toThrow("paged");
    await expect(api([{ body: paged }]).source.listAllTeamPermissions()).rejects.toThrow("paged");
    await expect(api([{ body: { ...paged, items: [serverTeam()] } }]).source.listUserTeams(USER_ID)).rejects.toThrow("paged");
  });

  test("the default makes one attempt and never sleeps (reads under a lock)", async () => {
    const { source, slept, requests } = api([{ status: 429, headers: { "retry-after": "5" } }]);
    await expect(source.getUser(USER_ID)).rejects.toThrow("failed");
    expect(requests.length).toBe(1);
    expect(slept).toEqual([]);
  });

  test("retries 429 and 5xx with Retry-After or backoff, then gives up", async () => {
    const { source, slept } = api([
      { status: 429, headers: { "retry-after": "2" } },
      { status: 503 },
      { body: { items: [serverTeam()], is_paginated: false } },
    ], { retries: 2 });
    expect(await source.listUserTeams(USER_ID)).toEqual([serverTeam()]);
    expect(slept).toEqual([2_000, 1_000]);
    await expect(api([{ status: 503 }, { status: 503 }], { retries: 1 }).source.getTeam(TEAM_ID)).rejects.toThrow("failed");
    expect(await api([{ status: -1 }, { body: serverTeam() }], { retries: 1 }).source.getTeam(TEAM_ID)).toEqual(serverTeam());
    await expect(api([{ status: -1 }, { status: -1 }], { retries: 1 }).source.getTeam(TEAM_ID)).rejects.toThrow("timed out");
  });

  test("lists direct permissions and pages users with cursors", async () => {
    const { source, requests } = api([
      { body: { items: [teamPermission()], is_paginated: false } },
      { body: { items: [serverUser()], is_paginated: true, pagination: { next_cursor: USER_ID } } },
    ]);
    expect(await source.listUserTeamPermissions(USER_ID)).toEqual([teamPermission()]);
    expect(requests[0]!.url.searchParams.get("recursive")).toBe("false");
    expect(await source.listUsersPage(null, 50)).toEqual({ items: [serverUser()], nextCursor: USER_ID });
    expect(Object.fromEntries(requests[1]!.url.searchParams)).toEqual({ limit: "50", include_anonymous: "true" });
  });

  test("bulk lists: a team's members and project-wide direct permissions", async () => {
    const { source, requests } = api([
      { body: { items: [serverUser()], is_paginated: true, pagination: { next_cursor: null } } },
      { body: { items: [teamPermission()], is_paginated: false } },
      { body: { items: [], is_paginated: false } },
    ]);
    expect(await source.listTeamMembersPage(TEAM_ID, null, 1000)).toEqual({ items: [serverUser()], nextCursor: null });
    expect(Object.fromEntries(requests[0]!.url.searchParams)).toEqual({ team_id: TEAM_ID, limit: "1000", include_anonymous: "true" });
    expect(await source.listAllTeamPermissions()).toEqual([teamPermission()]);
    expect(Object.fromEntries(requests[1]!.url.searchParams)).toEqual({ recursive: "false" });
    expect(await source.listAllProjectPermissions()).toEqual([]);
    expect(requests[2]!.url.pathname).toBe("/api/v1/project-permissions");
  });
});
