import { describe, expect, mock, test } from "bun:test";
import { NextRequest } from "next/server";

const realProGrants = await import("../services/admin/proGrants");
const realRouteAuth = await import("../services/admin/routeAuth");
const realAuditLog = await import("../services/admin/auditLog");

// An admin who double-submits the form races their own first grant for the
// same account's mutation lease. The loser must get a conflict, not a 500.
mock.module("../services/admin/routeAuth", () => ({
  ...realRouteAuth,
  requireAdmin: async () => ({
    ok: true,
    admin: { id: "admin-1", primaryEmail: "admin@manaflow.ai" },
  }),
}));
mock.module("../services/admin/auditLog", () => ({
  ...realAuditLog,
  withAdminAudit: async (_entry: unknown, operation: () => Promise<Response>) => await operation(),
}));
mock.module("../services/admin/proGrants", () => ({
  ...realProGrants,
  searchAdminUsers: async () => [
    { id: "u1", email: "pat@example.com", emailVerified: true },
  ],
  setManualPlanGrant: async () => {
    throw new realProGrants.AdminGrantConflictError("u1");
  },
}));

const { POST } = await import("../app/api/admin/email-grants/route");

describe("admin email grants conflict", () => {
  test("a grant that loses the account mutation lease returns 409", async () => {
    const response = await POST(
      new NextRequest("https://cmux.com/api/admin/email-grants", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          origin: "https://cmux.com",
          "sec-fetch-site": "same-origin",
        },
        body: JSON.stringify({ email: "pat@example.com", plan: "pro" }),
      }),
    );
    expect(response.status).toBe(409);
    expect(await response.json()).toEqual({ error: "mutation_in_progress" });
  });
});
