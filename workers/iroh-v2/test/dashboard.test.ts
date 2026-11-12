import { describe, expect, test } from "bun:test";
import { issueDashboardTicket, verifyDashboardTicket } from "../src/dashboard-auth";
import { encodeBase64URL, verifyTicket } from "../src/crypto";

const secret = encodeBase64URL(new Uint8Array(32).fill(91));
const authority = { environment: "staging", projectId: "project", teamId: "team", userId: "user", verifiedAt: 1000 };
const origin = "https://cmux.com";
const session = { authority, origin, clientInstanceId: "tab-1", canManageTeam: false };

describe("Dashboard authority stays separate from native devices", () => {
  test("one-hour ticket preserves its team, user, tab and approved origin", async () => {
    const ticket = await issueDashboardTicket(session, "key-1", secret);
    expect(ticket.expiresAt).toBe(4600);
    expect(ticket.refreshAfter).toBe(4300);
    const claims = await verifyDashboardTicket(ticket.token, { "key-1": secret }, "staging", "project", origin, 1100);
    expect(claims.authority).toEqual(authority);
    expect(claims.clientInstanceId).toBe("tab-1");
    expect(claims.canManageTeam).toBe(false);
    expect(claims).not.toHaveProperty("endpointId");
    expect(claims).not.toHaveProperty("deviceId");
  });

  test("cannot use a dashboard ticket as a native API ticket", async () => {
    const ticket = await issueDashboardTicket(session, "key-1", secret);
    await expect(verifyTicket(ticket.token, { "key-1": secret }, "staging", "project", 1100)).rejects.toMatchObject({ code: "unauthorized" });
  });

  test("rejects another origin, environment, signature, expiry and future issuance", async () => {
    const ticket = await issueDashboardTicket(session, "key-1", secret);
    await expect(verifyDashboardTicket(ticket.token, { "key-1": secret }, "staging", "project", "https://other.example", 1100)).rejects.toMatchObject({ code: "permission_denied" });
    await expect(verifyDashboardTicket(ticket.token, { "key-1": secret }, "production", "project", origin, 1100)).rejects.toMatchObject({ code: "environment_mismatch" });
    await expect(verifyDashboardTicket(ticket.token, { "key-1": encodeBase64URL(new Uint8Array(32).fill(92)) }, "staging", "project", origin, 1100)).rejects.toMatchObject({ code: "unauthorized" });
    await expect(verifyDashboardTicket(ticket.token, { "key-1": secret }, "staging", "project", origin, 4600)).rejects.toMatchObject({ code: "ticket_expired" });
    await expect(verifyDashboardTicket(ticket.token, { "key-1": secret }, "staging", "project", origin, 900)).rejects.toMatchObject({ code: "unauthorized" });
  });
});
