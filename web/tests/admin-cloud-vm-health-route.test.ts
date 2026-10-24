import { beforeEach, describe, expect, mock, test } from "bun:test";
import { NextRequest } from "next/server";

import type { StoredVmHealthReport, VmHealthReport } from "../services/vms/health/types";

type StackUser = {
  id: string;
  primaryEmail: string | null;
  primaryEmailVerified: boolean;
  isAnonymous: boolean;
  displayName?: string | null;
};

let currentUser: StackUser | null = null;
const directory = new Map<string, StackUser>();
const getUser = mock(async (arg?: unknown) => (typeof arg === "string" ? directory.get(arg) ?? null : currentUser));

mock.module("../app/lib/stack", () => ({
  getStackServerApp: () => ({ getUser }),
  isStackConfigured: () => true,
  promoteStackUserFromAnonymousViaApi: async () => undefined,
  stackServerApp: { getUser },
}));

let activeMembers = new Set<string>();
mock.module("../services/admin/members", () => ({
  findActiveAdminMember: async (email: string) => (activeMembers.has(email) ? { email } : null),
}));

let snapshotReads = 0;
let stored: StoredVmHealthReport | null = null;
const realStaffView = await import("../services/vms/health/staffView");
mock.module("../services/vms/health/staffView", () => ({
  ...realStaffView,
  latestStoredVmHealthReport: async () => {
    snapshotReads += 1;
    return stored;
  },
}));

const { GET } = await import("../app/api/admin/cloud-vm-health/route");

function report(): VmHealthReport {
  const owner = { cloudVmId: "row-1", userId: "user-1", teamId: "team-1" };
  return {
    version: 1,
    generatedAt: "2026-10-12T12:00:00.000Z",
    durationMs: 42_000,
    stateCounts: { running: 2 },
    workloadCounts: { cmux_cloud: 2 },
    coverage: { inventoryComplete: true, running: 2, probed: 2, probeErrors: 0, skippedBudget: 0, skippedIdle: 0 },
    hung: [{
      vmId: "vm-hung",
      workload: "cmux_cloud",
      owner,
      snapshot: "cmux-devbox",
      size: { cpu: 4, memoryMib: 8192, storageMib: 20480 },
      firstSeenHungAt: "2026-10-12T11:00:00.000Z",
      providerUpdatedAt: "2026-10-12T10:00:00.000Z",
      dbUpdatedAt: "2026-10-12T10:00:00.000Z",
      detail: "timeout after 10000ms",
    }],
    stuck: [],
    transitions: [],
    drift: [],
    tls: null,
    errors: [],
    attention: { needed: true, reasons: [{ code: "hung_vms", count: 1 }] },
  };
}

function request() {
  return new NextRequest("https://cmux.com/api/admin/cloud-vm-health");
}

function user(email: string, overrides: Partial<StackUser> = {}): StackUser {
  return { id: `id-${email}`, primaryEmail: email, primaryEmailVerified: true, isAnonymous: false, ...overrides };
}

describe("GET /api/admin/cloud-vm-health authorization", () => {
  beforeEach(() => {
    currentUser = null;
    activeMembers = new Set();
    snapshotReads = 0;
    stored = { id: "snap-1", createdAt: new Date(Date.now() - 60_000), report: report() };
    directory.clear();
    directory.set("user-1", user("owner@example.com", { id: "user-1", displayName: "Owner" }));
  });

  test("signed-out callers get 401 and never read the snapshot", async () => {
    const response = await GET(request());
    expect(response.status).toBe(401);
    expect(snapshotReads).toBe(0);
  });

  test("anonymous callers get 401", async () => {
    currentUser = user("anon@cmux.com", { isAnonymous: true });
    expect((await GET(request())).status).toBe(401);
    expect(snapshotReads).toBe(0);
  });

  test("a regular user gets 403 and no owner data", async () => {
    currentUser = user("someone@example.com");
    const response = await GET(request());
    expect(response.status).toBe(403);
    const body = await response.text();
    expect(body).not.toContain("owner@example.com");
    expect(body).not.toContain("vm-hung");
    expect(snapshotReads).toBe(0);
  });

  test("an unverified company email gets 403", async () => {
    currentUser = user("eve@cmux.com", { primaryEmailVerified: false });
    expect((await GET(request())).status).toBe(403);
    expect(snapshotReads).toBe(0);
  });

  test("a lookalike company domain gets 403", async () => {
    currentUser = user("eve@cmux.com.evil.example");
    expect((await GET(request())).status).toBe(403);
  });

  test("staff get the latest snapshot with owner emails, uncached", async () => {
    currentUser = user("ops@manaflow.ai");
    const response = await GET(request());
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    const body = await response.json() as { snapshot: { stale: boolean }; report: VmHealthReport; owners: Record<string, { email: string }> };
    expect(body.snapshot.stale).toBe(false);
    expect(body.report.hung[0]!.vmId).toBe("vm-hung");
    expect(body.owners["user-1"]!.email).toBe("owner@example.com");
    expect(snapshotReads).toBe(1);
  });

  test("an invited admin member with a verified email is staff", async () => {
    currentUser = user("contractor@example.com");
    activeMembers.add("contractor@example.com");
    expect((await GET(request())).status).toBe(200);
  });

  test("a stale snapshot is reported as stale", async () => {
    currentUser = user("ops@cmux.com");
    stored = { id: "snap-old", createdAt: new Date(Date.now() - 60 * 60_000), report: report() };
    const body = await (await GET(request())).json() as { snapshot: { stale: boolean } };
    expect(body.snapshot.stale).toBe(true);
  });
});
