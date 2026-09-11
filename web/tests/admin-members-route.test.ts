import { beforeEach, describe, expect, mock, test } from "bun:test";
import { NextRequest } from "next/server";

import { adminAuditLog } from "../db/schema";
import type { AdminAuditDb } from "../services/admin/auditLog";
import type { AdminMemberRecord, AdminMembersStore } from "../services/admin/members";

type StackUser = {
  id: string;
  primaryEmail: string | null;
  primaryEmailVerified: boolean;
  isAnonymous: boolean;
};

let currentUser: StackUser | null = null;
const getUser = mock(async () => currentUser);

mock.module("../app/lib/stack", () => ({
  getStackServerApp: () => ({ getUser }),
  isStackConfigured: () => true,
  promoteStackUserFromAnonymousViaApi: async () => undefined,
  stackServerApp: { getUser },
}));

const { createAdminMembersHandlers } = await import("../app/api/admin/members/handlers");

// In-memory member store: the same contract the drizzle store implements.
let members: AdminMemberRecord[] = [];
let nextId = 1;
const NOW = new Date("2026-09-09T12:00:00.000Z");

const store: AdminMembersStore = {
  async list() {
    return [...members];
  },
  async findByEmail(email) {
    return members.find((member) => member.email === email) ?? null;
  },
  async findById(id) {
    return members.find((member) => member.id === id) ?? null;
  },
  async insert(values) {
    const member: AdminMemberRecord = {
      id: `00000000-0000-4000-8000-00000000000${nextId++}`,
      ...values,
      invitedAt: NOW,
      acceptedAt: null,
      revokedAt: null,
      lastSeenAt: null,
    };
    members.push(member);
    return member;
  },
  async update(id, patch) {
    const index = members.findIndex((member) => member.id === id);
    if (index < 0) return null;
    members[index] = { ...members[index]!, ...patch };
    return members[index]!;
  },
  async reopen(id, patch) {
    const current = members.find((member) => member.id === id);
    if (!current || current.revokedAt === null) return null;
    return await store.update(id, patch);
  },
};

let auditRows: Array<Record<string, unknown>> = [];
const auditDb = {
  insert: (table: unknown) => ({
    values: async (values: Record<string, unknown>) => {
      if (table === adminAuditLog) auditRows.push(values);
    },
  }),
} as unknown as AdminAuditDb;

let sendResult = { sent: true };
const sendInvite = mock(async (): Promise<{ sent: boolean }> => sendResult);

const { GET, POST, DELETE } = createAdminMembersHandlers({ store, auditDb, sendInvite, now: () => NOW });

const admin = (): StackUser => ({
  id: "admin-1",
  primaryEmail: "lawrence@manaflow.ai",
  primaryEmailVerified: true,
  isAnonymous: false,
});

function mutation(body: unknown, method: "POST" | "DELETE" = "POST", headers: Record<string, string> = {}) {
  return new NextRequest("https://cmux.com/api/admin/members", {
    method,
    headers: {
      "content-type": "application/json",
      origin: "https://cmux.com",
      "sec-fetch-site": "same-origin",
      "x-vercel-id": "iad1::req-1",
      ...headers,
    },
    body: JSON.stringify(body),
  });
}

describe("admin members routes", () => {
  beforeEach(() => {
    currentUser = admin();
    members = [];
    nextId = 1;
    auditRows = [];
    sendResult = { sent: true };
    sendInvite.mockClear();
  });

  test("GET lists members and is admin-only", async () => {
    await POST(mutation({ email: "Pat@Example.com" }));
    const response = await GET(new NextRequest("https://cmux.com/api/admin/members"));
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(await response.json()).toEqual({
      members: [{
        id: "00000000-0000-4000-8000-000000000001",
        email: "pat@example.com",
        invitedByEmail: "lawrence@manaflow.ai",
        invitedAt: NOW.toISOString(),
        acceptedAt: null,
        revokedAt: null,
        lastSeenAt: null,
      }],
    });
    // An address with no member row and no company domain.
    currentUser = { id: "user", primaryEmail: "stranger@example.com", primaryEmailVerified: true, isAnonymous: false };
    expect((await GET(new NextRequest("https://cmux.com/api/admin/members"))).status).toBe(403);
  });

  test("POST creates the member, sends the invite, and audits it", async () => {
    const response = await POST(mutation({ email: "Pat@Example.com" }));
    expect(response.status).toBe(200);
    const body = (await response.json()) as { member: Record<string, unknown>; emailSent: boolean };
    expect(body.member).toMatchObject({ email: "pat@example.com", invitedByEmail: "lawrence@manaflow.ai" });
    expect(body.emailSent).toBe(true);
    expect(members[0]).toMatchObject({ email: "pat@example.com", invitedByUserId: "admin-1", revokedAt: null });
    expect(sendInvite).toHaveBeenCalledWith({ to: "pat@example.com", inviterEmail: "lawrence@manaflow.ai" });
    expect(auditRows).toEqual([expect.objectContaining({
      actorUserId: "admin-1",
      actorEmail: "lawrence@manaflow.ai",
      action: "member_invite",
      targetKind: "admin_member",
      targetLabel: "pat@example.com",
      outcome: "ok",
      error: null,
      requestId: "iad1::req-1",
    })]);
  });

  test("POST reports emailSent false when the sender is not configured", async () => {
    sendResult = { sent: false };
    const response = await POST(mutation({ email: "pat@example.com" }));
    expect(response.status).toBe(200);
    expect(((await response.json()) as { emailSent: boolean }).emailSent).toBe(false);
    expect(members).toHaveLength(1);
  });

  test("POST returns 409 for an active member and re-invites a revoked one", async () => {
    await POST(mutation({ email: "pat@example.com" }));
    const conflict = await POST(mutation({ email: "PAT@example.com " }));
    expect(conflict.status).toBe(409);
    expect(await conflict.json()).toEqual({ error: "already_member" });
    expect(sendInvite).toHaveBeenCalledTimes(1);
    expect(auditRows.at(-1)).toMatchObject({ action: "member_invite", outcome: "error", error: "already_member" });

    await store.update(members[0]!.id, { acceptedAt: NOW, lastSeenAt: NOW });
    await DELETE(mutation({ memberId: members[0]!.id }, "DELETE"));
    expect(members[0]?.revokedAt).toEqual(NOW);
    const reinvited = await POST(mutation({ email: "pat@example.com" }));
    expect(reinvited.status).toBe(200);
    expect(members).toHaveLength(1);
    // A re-invite starts a new tenure: nothing from the old one is shown.
    expect(members[0]).toMatchObject({ revokedAt: null, acceptedAt: null, lastSeenAt: null });
    expect(sendInvite).toHaveBeenCalledTimes(2);
  });

  test("POST returns 409 when a concurrent invite reopened the row first", async () => {
    await POST(mutation({ email: "pat@example.com" }));
    await DELETE(mutation({ memberId: members[0]!.id }, "DELETE"));
    // Simulate the race: the other request wins between findByEmail and reopen.
    const original = store.reopen;
    store.reopen = async (id, patch) => {
      await store.update(id, { revokedAt: null });
      return await original(id, patch);
    };
    try {
      const response = await POST(mutation({ email: "pat@example.com" }));
      expect(response.status).toBe(409);
      expect(await response.json()).toEqual({ error: "already_member" });
    } finally {
      store.reopen = original;
    }
    expect(sendInvite).toHaveBeenCalledTimes(1);
  });

  test("POST validates the body and the email, and rejects cross-site browser calls", async () => {
    const malformed = await POST(mutation({}));
    expect(malformed.status).toBe(400);
    // An authenticated admin's malformed request is still an audited action.
    expect(auditRows.at(-1)).toMatchObject({ action: "member_invite", targetLabel: null, outcome: "error", error: "invalid_body" });
    expect((await POST(mutation({ email: "   " }))).status).toBe(400);
    const junk = await POST(mutation({ email: "not-an-email" }));
    expect(junk.status).toBe(400);
    expect(await junk.json()).toEqual({ error: "invalid_email" });
    expect((await POST(mutation({ email: "x@example.com" }, "POST", {
      "sec-fetch-site": "cross-site",
      origin: "https://evil.example",
    }))).status).toBe(403);
    expect(members).toEqual([]);
    expect(sendInvite).not.toHaveBeenCalled();
  });

  test("DELETE revokes a member and audits it", async () => {
    await POST(mutation({ email: "pat@example.com" }));
    const response = await DELETE(mutation({ memberId: members[0]!.id }, "DELETE"));
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true });
    expect(members[0]?.revokedAt).toEqual(NOW);
    expect(auditRows.at(-1)).toMatchObject({
      action: "member_revoke",
      targetKind: "admin_member",
      targetId: members[0]!.id,
      outcome: "ok",
    });
    expect((await DELETE(mutation({ memberId: "00000000-0000-4000-8000-000000000009" }, "DELETE"))).status).toBe(404);
    expect((await DELETE(mutation({ memberId: "1; drop" }, "DELETE"))).status).toBe(400);
    expect((await DELETE(mutation({ memberId: "------------------------------------" }, "DELETE"))).status).toBe(400);
    expect(auditRows.at(-1)).toMatchObject({ action: "member_revoke", targetId: null, outcome: "error", error: "invalid_body" });
  });

  test("DELETE refuses a self-revoke", async () => {
    await POST(mutation({ email: "Lawrence@manaflow.ai" }));
    const response = await DELETE(mutation({ memberId: members[0]!.id }, "DELETE"));
    expect(response.status).toBe(400);
    expect(await response.json()).toEqual({ error: "self_revoke" });
    expect(members[0]?.revokedAt).toBeNull();
    expect(auditRows.at(-1)).toMatchObject({ action: "member_revoke", outcome: "error", error: "self_revoke" });
  });
});
