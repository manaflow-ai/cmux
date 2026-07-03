import { describe, expect, test } from "bun:test";
import {
  consumeRateLimitResetCredit,
  fetchRateLimitResetCredits,
  parseConsumeRateLimitResetCreditBody,
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
    const credit = result.rate_limit_reset_credits.credits[0];
    expect(credit).toBeDefined();
    if (!credit) throw new Error("missing credit");
    expect(credit.id).toBe("credit-1");
    expect(credit.status).toBe("available");
    const request = fetcher.requests[0];
    expect(request).toBeDefined();
    if (!request) throw new Error("missing request");
    expect(request.url).toBe(
      "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits",
    );
    expect(request.init.headers).toMatchObject({
      authorization: "Bearer test-token",
      "content-type": "application/json",
    });
  });

  test("normalizes bearer auth case", async () => {
    const response: RateLimitResetCreditsResponse = {
      rate_limit_reset_credits: { available_count: 0, credits: [] },
    };
    const fetcher = makeFetcher(200, response);

    await fetchRateLimitResetCredits("https://chatgpt.com", "bearer test-token", fetcher);

    const request = fetcher.requests[0];
    expect(request).toBeDefined();
    if (!request) throw new Error("missing request");
    expect(request.init.headers).toMatchObject({
      authorization: "Bearer test-token",
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

    const request = fetcher.requests[0];
    expect(request).toBeDefined();
    if (!request) throw new Error("missing request");
    expect(request.url).toBe(
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
  test("parses consume request bodies defensively", () => {
    expect(parseConsumeRateLimitResetCreditBody(null)).toBeNull();
    expect(parseConsumeRateLimitResetCreditBody({})).toBeNull();
    expect(parseConsumeRateLimitResetCreditBody({
      credit_id: "credit-1",
      redeem_request_id: "req-1",
    })).toEqual({
      credit_id: "credit-1",
      redeem_request_id: "req-1",
    });
  });

  test("posts credit_id and redeem_request_id", async () => {
    const fetcher = makeFetcher(200, { success: true });

    const result = (await consumeRateLimitResetCredit(
      "https://chatgpt.com",
      "test-token",
      { credit_id: "credit-1", redeem_request_id: "req-1" },
      fetcher,
    )) as { success: boolean };

    expect(result.success).toBe(true);
    const requestRecord = fetcher.requests[0];
    expect(requestRecord).toBeDefined();
    if (!requestRecord) throw new Error("missing request");
    expect(requestRecord.url).toBe(
      "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/consume",
    );
    expect(requestRecord.init.method).toBe("POST");
    expect(JSON.parse((requestRecord.init.body as string) ?? "{}")).toEqual({
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
