import { describe, expect, test } from "bun:test";
import { captureSentryException } from "../src/sentry";

describe("captureSentryException", () => {
  test("emits a Sentry envelope with exception context", async () => {
    let request: Request | undefined;
    await captureSentryException(
      { SENTRY_DSN: "https://public@example.test/42" },
      "user-1",
      new Error("upstream failed"),
      { durable_object: "TeamPresence", operation: "alarm", team_id: "team-1" },
      async (input, init) => {
        request = new Request(input, init);
        return new Response("ok", { status: 200 });
      },
    );

    expect(request?.url).toContain("https://example.test/api/42/envelope/");
    expect(request?.headers.get("content-type")).toBe("application/x-sentry-envelope");
    const lines = (await request?.text())?.split("\n") ?? [];
    const event = JSON.parse(lines[2]) as Record<string, any>;
    expect(event.platform).toBe("javascript");
    expect(event.user.id).toBe("user-1");
    expect(event.exception.values[0].value).toBe("upstream failed");
    expect(event.tags.operation).toBe("alarm");
  });

  test("swallows telemetry transport failures and missing DSNs", async () => {
    await expect(captureSentryException({}, "user-1", "boom", {}, async () => {
      throw new Error("sentry unavailable");
    })).resolves.toBeUndefined();
  });
});
