import { afterEach, beforeEach, describe, expect, mock, test } from "bun:test";

const realTeamSeats = await import("../services/billing/teamSeats");
let outcome: () => Promise<Awaited<ReturnType<typeof realTeamSeats.reconcileTeamSeats>>> = async () =>
  ({ checked: 0, updated: 0, skipped: 0, failed: 0, busy: 0 });
let calls = 0;
mock.module("../services/billing/teamSeats", () => ({
  ...realTeamSeats,
  reconcileTeamSeats: async () => {
    calls += 1;
    return outcome();
  },
}));

const { GET } = await import("../app/api/cron/team-seats/route");
const originalCronSecret = process.env.CRON_SECRET;

beforeEach(() => {
  process.env.CRON_SECRET = "cron-secret";
  calls = 0;
});

afterEach(() => {
  if (originalCronSecret === undefined) delete process.env.CRON_SECRET;
  else process.env.CRON_SECRET = originalCronSecret;
});

function request(authorization?: string): Request {
  return new Request("https://cmux.test/api/cron/team-seats", authorization ? { headers: { authorization } } : {});
}

describe("team seats cron route", () => {
  test("rejects a missing or wrong bearer secret before reconciling", async () => {
    expect((await GET(request())).status).toBe(401);
    expect((await GET(request("Bearer wrong"))).status).toBe(401);
    expect(calls).toBe(0);
  });

  test("reports the run and is 200 with no failures", async () => {
    outcome = async () => ({ checked: 2, updated: 1, skipped: 1, failed: 0, busy: 0 });
    const response = await GET(request("Bearer cron-secret"));
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true, checked: 2, updated: 1, skipped: 1, failed: 0, busy: 0 });
  });

  test("is 503 when a team failed so the run is retried", async () => {
    outcome = async () => ({ checked: 1, updated: 0, skipped: 0, failed: 1, busy: 0 });
    expect((await GET(request("Bearer cron-secret"))).status).toBe(503);
    outcome = async () => { throw new Error("db down"); };
    const response = await GET(request("Bearer cron-secret"));
    expect(response.status).toBe(503);
    expect(response.headers.get("retry-after")).toBe("60");
  });
});
