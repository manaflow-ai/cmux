import { describe, expect, mock, test } from "bun:test";

const getUser = mock(async () => null);

mock.module("../app/lib/stack", () => ({
  getStackServerApp: () => ({ getUser }),
  isStackConfigured: () => true,
  stackServerApp: { getUser },
}));

const { GET, POST } = await import("../app/api/mcp/route");

describe("/api/mcp route", () => {
  test("an unauthenticated call is a 401 with a bearer challenge, before any tool runs", async () => {
    const response = await POST(new Request("https://cmux.com/api/mcp", {
      method: "POST",
      headers: { "content-type": "application/json", accept: "application/json, text/event-stream" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "list_machines", arguments: {} } }),
    }));
    expect(response.status).toBe(401);
    expect(response.headers.get("www-authenticate")).toBe('Bearer realm="cmux"');
  });

  test("GET has no stream to offer", () => {
    const response = GET();
    expect(response.status).toBe(405);
    expect(response.headers.get("allow")).toBe("POST");
  });
});
