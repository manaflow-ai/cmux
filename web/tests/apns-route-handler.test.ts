import { describe, expect, mock, test } from "bun:test";

import { withApnsApiRoute } from "../services/apns/routeHandler";

describe("APNs route handler", () => {
  test("records unexpected failures as generic API errors", async () => {
    const originalError = console.error;
    console.error = mock(() => {}) as unknown as typeof console.error;
    try {
      const response = await withApnsApiRoute(
        new Request("https://cmux.test/api/notifications/push", { method: "POST" }),
        "/api/notifications/push",
        "send",
        async () => {
          throw new Error("database connection failed");
        },
      );

      expect(response.status).toBe(500);
      expect(await response.json()).toEqual({ error: "push_internal_error" });
      const calls = (console.error as unknown as { mock: { calls: unknown[][] } }).mock.calls;
      expect(calls[0]?.[0]).toBe("/api/notifications/push send failed");
      expect(calls[0]?.[1]).toBeInstanceOf(Error);
    } finally {
      console.error = originalError;
    }
  });
});
