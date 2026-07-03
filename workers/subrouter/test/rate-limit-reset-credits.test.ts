import { describe, expect, test } from "bun:test";
import {
  consumeRateLimitResetCredit,
  fetchRateLimitResetCredits,
  type RateLimitResetCreditsResponse,
} from "../src/rate-limit-reset-credits";

describe("fetchRateLimitResetCredits", () => {
  test("returns parsed credits on success", async () => {
    const response: RateLimitResetCreditsResponse = {
      rate_limit_reset_credits: {
        available_count: 1,
        credits: [
          {
            id: "credit-1",
            status: "available",
            title: "One rate limit reset",
            description: "You have one rate limit reset ready to be redeemed",
            profile_user_id: "@codex-team",
          },
        ],
      },
    };
    const fetcher = makeFetcher(200, response);

    const result = await fetchRateLimitResetCredits(
      "https://chatgpt.com",
      "test-token",
      fetcher,
    );

    expect(result.rate_limit_reset_credits.available_count).toBe(1);
    expect(result.rate_limit_reset_credits.credits[0].id).toBe("credit-1");
    expect(result.rate_limit_reset_credits.credits[0].status).toBe("available");
    expect(fetcher.requests[0].url).toBe(
      "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits",
    );
    expect(fetcher.requests[0].init.headers).toMatchObject({
      authorization: "Bearer test-token",
      "content-type": "application/json",
    });
  });

  test("normalizes a backend-api/codex base URL", async () => {
    const response: RateLimitResetCreditsResponse = {
      rate_limit_reset_credits: { available_count: 0, credits: [] },
    };
    const fetcher = makeFetcher(200, response);

    await fetchRateLimitResetCredits(
      "https://chatgpt.com/backend-api/codex",
      "test-token",
      fetcher,
    );

    expect(fetcher.requests[0].url).toBe(
      "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits",
    );
  });

  test("throws on upstream error", async () => {
    const fetcher = makeFetcher(500, { error: "internal" });

    await expect(
      fetchRateLimitResetCredits("https://chatgpt.com", "test-token", fetcher),
    ).rejects.toThrow("fetch failed: 500");
  });
});

describe("consumeRateLimitResetCredit", () => {
  test("posts credit_id and redeem_request_id", async () => {
    const fetcher = makeFetcher(200, { success: true });

    const result = (await consumeRateLimitResetCredit(
      "https://chatgpt.com",
      "test-token",
      { credit_id: "credit-1", redeem_request_id: "req-1" },
      fetcher,
    )) as { success: boolean };

    expect(result.success).toBe(true);
    expect(fetcher.requests[0].url).toBe(
      "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/consume",
    );
    expect(fetcher.requests[0].init.method).toBe("POST");
    expect(JSON.parse((fetcher.requests[0].init.body as string) ?? "{}")).toEqual({
      credit_id: "credit-1",
      redeem_request_id: "req-1",
    });
  });
});

function makeFetcher(status: number, body: unknown): typeof fetch & { requests: RequestRecord[] } {
  const requests: RequestRecord[] = [];
  const fetcher = (async (input: RequestInfo | URL, init?: RequestInit) => {
    requests.push({ url: input.toString(), init: init ?? {} });
    return new Response(JSON.stringify(body), {
      status,
      headers: { "content-type": "application/json" },
    });
  }) as typeof fetch & { requests: RequestRecord[] };
  fetcher.requests = requests;
  return fetcher;
}

interface RequestRecord {
  url: string;
  init: RequestInit;
}
