import { afterAll, beforeEach, describe, expect, mock, test } from "bun:test";
import type { AuthedUser } from "../services/vms/auth";
import { ADMIN_ID, MEMBER_ID, MemoryInviteStore, noLock, OUTSIDER_ID, standardTeam, TEAM_ID, type FakeStack } from "./teams-fixture";

let stack: FakeStack = standardTeam();
let store = new MemoryInviteStore();
let currentUserId: string | null = ADMIN_ID;
let activeSubscription = false;

function authedUser(id: string): AuthedUser {
  return {
    id,
    displayName: null,
    primaryEmail: null,
    billingCustomerType: "user",
    billingTeamId: id,
    selectedTeamId: null,
    teams: [],
    teamIds: [],
    userBillingPlanId: null,
    billingPlanId: null,
    billingSeats: null,
  };
}

const realAuth = await import("../services/vms/auth");
mock.module("../services/vms/auth", () => ({
  ...realAuth,
  verifyRequest: async () => (currentUserId ? authedUser(currentUserId) : null),
}));
mock.module("../app/lib/stack", () => ({
  getStackServerApp: () => stack.app(),
  isStackConfigured: () => true,
}));
const realRepository = await import("../services/teams/repository");
mock.module("../services/teams/repository", () => ({
  ...realRepository,
  get databaseTeamInviteStore() {
    return store;
  },
  withTeamAdminLock: noLock,
}));
const seatFacts: string[] = [];
const realSeatSync = await import("../services/teams/seatSync");
mock.module("../services/teams/seatSync", () => ({
  ...realSeatSync,
  defaultTeamSeatSync: { membershipChanged: async (teamId: string) => { seatFacts.push(teamId); } },
}));
const realPro = await import("../services/billing/pro");
mock.module("../services/billing/pro", () => ({
  ...realPro,
  hasActiveTeamSubscriptionForTeam: async () => activeSubscription,
}));

// bun's mock.module is process-global: later suite files (billing-team-routes
// reads the real plan resolver) must see the real modules again.
afterAll(() => {
  mock.module("../services/vms/auth", () => realAuth);
  mock.module("../services/teams/repository", () => realRepository);
  mock.module("../services/teams/seatSync", () => realSeatSync);
  mock.module("../services/billing/pro", () => realPro);
});

const teamsRoute = await import("../app/api/teams/route");
const teamRoute = await import("../app/api/teams/[teamId]/route");
const linksRoute = await import("../app/api/teams/[teamId]/links/route");
const linkRoute = await import("../app/api/teams/[teamId]/links/[linkId]/route");
const memberRoute = await import("../app/api/teams/[teamId]/members/[userId]/route");
const joinRoute = await import("../app/api/teams/join/[token]/route");

const ORIGIN = "https://cmux.test";

function browserRequest(path: string, init: { method?: string; body?: unknown; origin?: string | null } = {}): Request {
  const headers = new Headers({ "content-type": "application/json" });
  if (init.origin !== null) headers.set("origin", init.origin ?? ORIGIN);
  return new Request(`${ORIGIN}${path}`, {
    method: init.method ?? "GET",
    headers,
    body: init.body === undefined ? undefined : JSON.stringify(init.body),
  });
}

function params<T extends Record<string, string>>(value: T) {
  return { params: Promise.resolve(value) };
}

beforeEach(() => {
  stack = standardTeam();
  store = new MemoryInviteStore();
  currentUserId = ADMIN_ID;
  activeSubscription = false;
});

describe("team routes", () => {
  test("refuses cross-origin browser mutations before authenticating", async () => {
    const response = await teamsRoute.POST(browserRequest("/api/teams", {
      method: "POST",
      body: { displayName: "X" },
      origin: "https://evil.example",
    }));
    expect(response.status).toBe(403);
    expect((await response.json() as { error: { code: string } }).error.code).toBe("forbidden");
  });

  test("returns 401 in the contract error shape without a session", async () => {
    currentUserId = null;
    const response = await teamRoute.GET(browserRequest(`/api/teams/${TEAM_ID}`), params({ teamId: TEAM_ID }));
    expect(response.status).toBe(401);
    expect((await response.json() as { error: { code: string } }).error.code).toBe("unauthorized");
  });

  test("creates a team with the creator as admin", async () => {
    const response = await teamsRoute.POST(browserRequest("/api/teams", { method: "POST", body: { displayName: " Platform " } }));
    expect(response.status).toBe(201);
    const body = await response.json() as { team: { id: string; displayName: string } };
    expect(body.team.displayName).toBe("Platform");
    expect(stack.grantsOf(body.team.id, ADMIN_ID).has("team_admin")).toBe(true);
  });

  test("GET returns the detail to a member and team_not_found to an outsider", async () => {
    currentUserId = MEMBER_ID;
    const member = await teamRoute.GET(browserRequest(`/api/teams/${TEAM_ID}`), params({ teamId: TEAM_ID }));
    expect(member.status).toBe(200);
    const detail = await member.json() as { viewer: { role: string }; invitations: unknown[] };
    expect(detail.viewer.role).toBe("member");

    currentUserId = OUTSIDER_ID;
    const outsider = await teamRoute.GET(browserRequest(`/api/teams/${TEAM_ID}`), params({ teamId: TEAM_ID }));
    expect(outsider.status).toBe(403);
    expect((await outsider.json() as { error: { code: string } }).error.code).toBe("team_not_found");
  });

  test("a member cannot create links; an admin can, then the link joins and revokes", async () => {
    currentUserId = MEMBER_ID;
    const refused = await linksRoute.POST(
      browserRequest(`/api/teams/${TEAM_ID}/links`, { method: "POST", body: { expiresInDays: 7, maxUses: 2 } }),
      params({ teamId: TEAM_ID }),
    );
    expect(refused.status).toBe(403);

    currentUserId = ADMIN_ID;
    const created = await linksRoute.POST(
      browserRequest(`/api/teams/${TEAM_ID}/links`, { method: "POST", body: { expiresInDays: 7, maxUses: 2 } }),
      params({ teamId: TEAM_ID }),
    );
    expect(created.status).toBe(201);
    const { link, url } = await created.json() as { link: { id: string; role: string }; url: string };
    expect(link.role).toBe("member");
    const token = url.split("/join/")[1]!;
    expect(url.startsWith(`${ORIGIN}/en/join/`)).toBe(true);

    currentUserId = OUTSIDER_ID;
    const preview = await joinRoute.GET(browserRequest(`/api/teams/join/${token}`), params({ token }));
    expect(await preview.json()).toEqual({ teamDisplayName: "Acme", alreadyMember: false });
    const joined = await joinRoute.POST(browserRequest(`/api/teams/join/${token}`, { method: "POST" }), params({ token }));
    expect(await joined.json()).toEqual({ teamId: TEAM_ID });

    currentUserId = ADMIN_ID;
    const revoked = await linkRoute.DELETE(
      browserRequest(`/api/teams/${TEAM_ID}/links/${link.id}`, { method: "DELETE" }),
      params({ teamId: TEAM_ID, linkId: link.id }),
    );
    expect(revoked.status).toBe(200);
    currentUserId = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
    stack.addUser({ id: currentUserId });
    const after = await joinRoute.POST(browserRequest(`/api/teams/join/${token}`, { method: "POST" }), params({ token }));
    expect(after.status).toBe(410);
    expect((await after.json() as { error: { code: string } }).error.code).toBe("link_invalid");
  });

  test("the sole admin cannot demote themself through the route", async () => {
    const response = await memberRoute.PATCH(
      browserRequest(`/api/teams/${TEAM_ID}/members/${ADMIN_ID}`, { method: "PATCH", body: { role: "member" } }),
      params({ teamId: TEAM_ID, userId: ADMIN_ID }),
    );
    expect(response.status).toBe(409);
    expect((await response.json() as { error: { code: string } }).error.code).toBe("last_admin");
  });

  test("DELETE refuses a team with an active subscription", async () => {
    activeSubscription = true;
    const response = await teamRoute.DELETE(
      browserRequest(`/api/teams/${TEAM_ID}`, { method: "DELETE" }),
      params({ teamId: TEAM_ID }),
    );
    expect(response.status).toBe(409);
    expect((await response.json() as { error: { code: string } }).error.code).toBe("team_has_active_subscription");
    expect(stack.teams.has(TEAM_ID)).toBe(true);
  });
});
