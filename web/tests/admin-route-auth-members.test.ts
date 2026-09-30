import { beforeEach, describe, expect, mock, test } from "bun:test";
import { NextRequest } from "next/server";

import { adminMembers } from "../db/schema";

const dbClientModule = await import("../db/client");
const realCloseCloudDbForTests = dbClientModule.closeCloudDbForTests;
const realCreateAwsRdsIamPool = dbClientModule.createAwsRdsIamPool;

type StackUser = {
  id: string;
  primaryEmail: string | null;
  primaryEmailVerified: boolean;
  isAnonymous: boolean;
};

let stackConfigured = true;
let currentUser: StackUser | null = null;
const getUser = mock(async () => currentUser);

mock.module("../app/lib/stack", () => ({
  getStackServerApp: () => ({ getUser }),
  isStackConfigured: () => stackConfigured,
  promoteStackUserFromAnonymousViaApi: async () => undefined,
  stackServerApp: { getUser },
}));

let memberRows: Array<Record<string, unknown>> = [];
let membersLookupFails = false;
let memberLookups = 0;

mock.module("../db/client", () => ({
  createAwsRdsIamPool: realCreateAwsRdsIamPool,
  closeCloudDbForTests: realCloseCloudDbForTests,
  cloudDb: () => ({
    select: () => ({
      from: (table: unknown) => ({
        where: () => ({
          limit: async () => {
            if (table !== adminMembers) return [];
            memberLookups += 1;
            if (membersLookupFails) {
              throw Object.assign(new Error("relation \"admin_members\" does not exist"), { code: "42P01" });
            }
            return memberRows;
          },
        }),
      }),
    }),
  }),
}));

const { requireAdmin } = await import("../services/admin/routeAuth");

function request() {
  return new NextRequest("https://cmux.com/api/admin/members/me");
}

function memberRow(overrides: Partial<Record<string, unknown>> = {}) {
  return {
    id: "11111111-2222-4333-8444-555555555555",
    email: "pat@example.com",
    invitedByUserId: "admin-1",
    invitedByEmail: "lawrence@manaflow.ai",
    invitedAt: new Date("2026-09-09T00:00:00.000Z"),
    acceptedAt: null,
    revokedAt: null,
    lastSeenAt: null,
    ...overrides,
  };
}

describe("requireAdmin member rule", () => {
  beforeEach(() => {
    stackConfigured = true;
    memberRows = [];
    membersLookupFails = false;
    memberLookups = 0;
  });

  test("company-domain admins are admitted without a member lookup", async () => {
    currentUser = { id: "admin-1", primaryEmail: "lawrence@manaflow.ai", primaryEmailVerified: true, isAnonymous: false };
    const gate = await requireAdmin(request());
    expect(gate.ok).toBe(true);
    if (gate.ok) {
      expect(gate.source).toBe("company_domain");
      expect(gate.admin).toEqual({ id: "admin-1", primaryEmail: "lawrence@manaflow.ai" });
    }
    expect(memberLookups).toBe(0);
  });

  test("a verified email with an active member row is admitted as a member", async () => {
    memberRows = [memberRow()];
    currentUser = { id: "u1", primaryEmail: "Pat@Example.com", primaryEmailVerified: true, isAnonymous: false };
    const gate = await requireAdmin(request());
    expect(gate.ok).toBe(true);
    if (gate.ok) expect(gate.source).toBe("member");
    expect(memberLookups).toBe(1);
  });

  test("revoked, missing, and unverified members are forbidden", async () => {
    memberRows = [memberRow({ revokedAt: new Date("2026-09-09T01:00:00.000Z") })];
    currentUser = { id: "u1", primaryEmail: "pat@example.com", primaryEmailVerified: true, isAnonymous: false };
    let gate = await requireAdmin(request());
    expect(gate.ok).toBe(false);
    if (!gate.ok) expect(gate.response.status).toBe(403);

    memberRows = [];
    gate = await requireAdmin(request());
    expect(gate.ok).toBe(false);

    memberRows = [memberRow()];
    currentUser = { id: "u1", primaryEmail: "pat@example.com", primaryEmailVerified: false, isAnonymous: false };
    const lookupsBefore = memberLookups;
    gate = await requireAdmin(request());
    expect(gate.ok).toBe(false);
    if (!gate.ok) expect(gate.response.status).toBe(403);
    expect(memberLookups).toBe(lookupsBefore);
  });

  test("anonymous and signed-out callers stay 401", async () => {
    memberRows = [memberRow()];
    currentUser = { id: "anon", primaryEmail: "pat@example.com", primaryEmailVerified: true, isAnonymous: true };
    let gate = await requireAdmin(request());
    expect(gate.ok).toBe(false);
    if (!gate.ok) expect(gate.response.status).toBe(401);
    currentUser = null;
    gate = await requireAdmin(request());
    expect(gate.ok).toBe(false);
    if (!gate.ok) expect(gate.response.status).toBe(401);
    expect(memberLookups).toBe(0);
  });

  test("a failed member lookup fails closed with 403 and a logged event", async () => {
    membersLookupFails = true;
    const logged: unknown[][] = [];
    const consoleError = console.error;
    console.error = (...args: unknown[]) => {
      logged.push(args);
    };
    try {
      currentUser = { id: "u1", primaryEmail: "pat@example.com", primaryEmailVerified: true, isAnonymous: false };
      const gate = await requireAdmin(request());
      expect(gate.ok).toBe(false);
      if (!gate.ok) expect(gate.response.status).toBe(403);
    } finally {
      console.error = consoleError;
    }
    expect(logged[0]?.[0]).toBe("admin.members.lookup_failed");
  });
});
