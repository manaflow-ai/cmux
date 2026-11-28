import { describe, expect, test } from "bun:test";
import { routeDashboard } from "../src/dashboard-routing";
import { encodeBase64URL } from "../src/crypto";

const authority = { environment: "staging", projectId: "project", teamId: "team", userId: "user", verifiedAt: 1000 };
const secret = encodeBase64URL(new Uint8Array(32).fill(41));
const calls: Request[] = [];
const services = {
  environment: "staging", projectId: "project", keys: { current: secret }, currentKeyId: "current", currentKey: secret,
  allowedOrigins: ["https://cmux.com"], now: () => 1100,
  stack: { verify: async () => authority, canManageTeam: async () => true },
  charge: async () => {}, dispatchTeam: async (_team: string, request: Request) => { calls.push(request); return new Response(null, { status: 200 }); },
};

describe("Dashboard browser bootstrap", () => {
  test("allows only the configured origin and returns a scoped ticket", async () => {
    calls.length = 0;
    const requestId = "dashboard-open";
    const response = await routeDashboard(new Request("https://worker/v2/dashboard/session", {
      method: "POST", headers: { origin: "https://cmux.com", authorization: "Bearer stack", "content-type": "application/json" },
      body: JSON.stringify({ schemaId: "dashboard.open.v1", requestId, environment: "staging", projectId: "project", teamId: "team", userId: "user", clientInstanceId: "tab" }),
    }), services);
    expect(response.status).toBe(200);
    expect(response.headers.get("access-control-allow-origin")).toBe("https://cmux.com");
    const body = await response.json() as any;
    expect(body.schemaId).toBe("dashboard.ready.v1");
    expect(body.ticket.token).toContain(".");
  });

  test("does not authenticate or allocate a team socket for an unapproved origin", async () => {
    const response = await routeDashboard(new Request("https://worker/v2/dashboard/session", {
      method: "POST", headers: { origin: "https://evil.example", authorization: "Bearer stack", "content-type": "application/json" },
      body: JSON.stringify({ schemaId: "dashboard.open.v1", requestId: "evil", environment: "staging", projectId: "project", teamId: "team", userId: "user", clientInstanceId: "tab" }),
    }), services);
    expect(response.status).toBe(403);
  });

  test("passes a verified ticket to the team object without putting it in the URL", async () => {
    const ready = await routeDashboard(new Request("https://worker/v2/dashboard/session", {
      method: "POST", headers: { origin: "https://cmux.com", authorization: "Bearer stack", "content-type": "application/json" },
      body: JSON.stringify({ schemaId: "dashboard.open.v1", requestId: "socket-ticket", environment: "staging", projectId: "project", teamId: "team", userId: "user", clientInstanceId: "tab" }),
    }), services);
    const token = (await ready.json() as any).ticket.token;
    const response = await routeDashboard(new Request("https://worker/v2/dashboard/socket", {
      headers: { origin: "https://cmux.com", upgrade: "websocket", "sec-websocket-protocol": `cmux-v2-dashboard, ticket.${token}` },
    }), services);
    expect(response.status).toBe(200);
    expect(calls.length).toBeGreaterThan(0);
    expect(calls[calls.length - 1]?.headers.get("x-cmux-v2-dashboard-authority")).toContain("team");
    expect(calls[calls.length - 1]?.url.includes(token)).toBe(false);
    expect(calls[calls.length - 1]?.headers.get("x-cmux-v2-dashboard-authority")).toContain("team");
  });
});
