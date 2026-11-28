import { afterEach, describe, expect, test } from "bun:test";

const originalCronSecret = process.env.CRON_SECRET;

const route = await import("../app/api/internal/vm/leases/revoke-expired/route");

afterEach(() => {
  restoreEnv("CRON_SECRET", originalCronSecret);
});

describe("VM expired lease cron route", () => {
  test("does not expose the secret env var name when the cron secret is missing", async () => {
    delete process.env.CRON_SECRET;

    const response = await route.POST(
      new Request("https://cmux.test/api/internal/vm/leases/revoke-expired", {
        method: "POST",
      }),
    );

    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ error: "service_unavailable" });
  });

  test("requires the configured cron secret before revoking expired leases", async () => {
    process.env.CRON_SECRET = "cron-secret";

    const response = await route.POST(
      new Request("https://cmux.test/api/internal/vm/leases/revoke-expired", {
        method: "POST",
        headers: { authorization: "Bearer wrong" },
      }),
    );

    expect(response.status).toBe(401);
    expect(await response.json()).toEqual({ error: "unauthorized" });
  });
});

function restoreEnv(key: string, value: string | undefined): void {
  if (typeof value === "undefined") {
    delete process.env[key];
  } else {
    process.env[key] = value;
  }
}
