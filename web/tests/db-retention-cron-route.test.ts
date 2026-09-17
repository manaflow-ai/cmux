import { afterEach, describe, expect, test } from "bun:test";

const originalCronSecret = process.env.CRON_SECRET;

const route = await import("../app/api/cron/db-retention/route");

afterEach(() => {
  if (typeof originalCronSecret === "undefined") {
    delete process.env.CRON_SECRET;
  } else {
    process.env.CRON_SECRET = originalCronSecret;
  }
});

describe("db retention cron route", () => {
  test("reports service unavailable without naming the secret when the cron secret is missing", async () => {
    delete process.env.CRON_SECRET;

    const response = await route.POST(new Request("https://cmux.test/api/cron/db-retention", { method: "POST" }));

    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ error: "service_unavailable" });
  });

  test("requires the configured cron secret before draining", async () => {
    process.env.CRON_SECRET = "cron-secret";

    const response = await route.POST(
      new Request("https://cmux.test/api/cron/db-retention", {
        method: "POST",
        headers: { authorization: "Bearer wrong" },
      }),
    );

    expect(response.status).toBe(401);
    expect(await response.json()).toEqual({ error: "unauthorized" });
  });
});
