import { afterAll, beforeEach, describe, expect, mock, test } from "bun:test";

const OLD_TOKEN = process.env.CODEROUTER_INTERNAL_TOKEN;
const runCoderouterWorkflow = mock(async () => ({ balanceMicros: 0 }));
const ingestUsage = mock((input: unknown) => input);
const poolConfigForName = mock((input: unknown) => input);

mock.module("../services/coderouter/workflows", () => ({
  ingestUsage,
  poolConfigForName,
  runCoderouterWorkflow,
}));

beforeEach(() => {
  process.env.CODEROUTER_INTERNAL_TOKEN = "internal-token";
  runCoderouterWorkflow.mockClear();
  runCoderouterWorkflow.mockResolvedValue({ balanceMicros: 0 });
  ingestUsage.mockClear();
  poolConfigForName.mockClear();
});

afterAll(() => {
  process.env.CODEROUTER_INTERNAL_TOKEN = OLD_TOKEN;
});

describe("coderouter routes", () => {
  test("internal pool-config rejects missing service token", async () => {
    const { GET } = await import("../app/api/coderouter/internal/pool-config/route");

    const response = await GET(new Request("https://cmux.test/api/coderouter/internal/pool-config?poolId=team-1:openai"));

    expect(response.status).toBe(401);
    expect(await response.json()).toEqual({ error: "unauthorized", message: "Unauthorized." });
  });

  test("usage-ingest validates request bodies before running workflows", async () => {
    const { POST } = await import("../app/api/coderouter/internal/usage-ingest/route");

    const response = await POST(new Request("https://cmux.test/api/coderouter/internal/usage-ingest", {
      method: "POST",
      headers: {
        authorization: "Bearer internal-token",
        "content-type": "application/json",
      },
      body: JSON.stringify({
        poolId: "team-1:openai",
        events: [{ eventId: "event-1", status: 200 }],
      }),
    }));

    expect(response.status).toBe(400);
    const body = await response.json();
    expect(body.error).toBe("invalid_request");
    expect(runCoderouterWorkflow).not.toHaveBeenCalled();
  });

  test("usage-ingest accepts a full 500-event worker flush larger than the public JSON cap", async () => {
    const { POST } = await import("../app/api/coderouter/internal/usage-ingest/route");
    const events = Array.from({ length: 500 }, (_, index) => ({
      eventId: `event-${index}`,
      family: "openai",
      endpointClass: "openai_api",
      model: "gpt-5",
      credentialClass: "managed",
      status: 200,
      inputTokens: 1000,
      outputTokens: 1000,
      cacheReadTokens: 1000,
      cacheWriteTokens: 0,
      estimated: false,
      latencyMs: 250,
      ts: 1_777_000_000_000 + index,
    }));
    const body = JSON.stringify({ poolId: "team-1:openai", events });
    expect(body.length).toBeGreaterThan(64 * 1024);

    const response = await POST(new Request("https://cmux.test/api/coderouter/internal/usage-ingest", {
      method: "POST",
      headers: {
        authorization: "Bearer internal-token",
        "content-type": "application/json",
        "content-length": String(body.length),
      },
      body,
    }));

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ balanceMicros: 0 });
    expect(runCoderouterWorkflow).toHaveBeenCalled();
  });
});
