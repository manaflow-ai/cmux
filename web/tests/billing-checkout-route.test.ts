import { beforeEach, describe, expect, mock, test } from "bun:test";
import { NextRequest } from "next/server";

const signedInUser = {
  id: "user-signed-in",
  createCheckoutUrl: mock(async () => "https://checkout.test/signed-in"),
};
const anonymousUser = {
  id: "user-anonymous",
  isAnonymous: true,
  createCheckoutUrl: mock(async () => "https://checkout.test/anonymous"),
};

let userResponses: unknown[] = [];
const getUser = mock(async () => userResponses.shift() ?? null);
const hasActiveProSubscription = mock(async () => false);
const syncProPlanMetadata = mock(async () => undefined);

mock.module("../app/lib/stack", () => ({
  stackServerApp: { getUser },
}));

mock.module("../services/billing/pro", () => ({
  PRO_PRODUCT_ID: "pro",
  hasActiveProSubscription,
  syncProPlanMetadata,
}));

const { GET } = await import("../app/api/billing/checkout/route");

describe("billing checkout route", () => {
  beforeEach(() => {
    getUser.mockClear();
    hasActiveProSubscription.mockClear();
    syncProPlanMetadata.mockClear();
    signedInUser.createCheckoutUrl.mockClear();
    anonymousUser.createCheckoutUrl.mockClear();
    signedInUser.createCheckoutUrl.mockResolvedValue("https://checkout.test/signed-in");
    anonymousUser.createCheckoutUrl.mockResolvedValue("https://checkout.test/anonymous");
    hasActiveProSubscription.mockResolvedValue(false);
    userResponses = [];
  });

  test("sends signed-out visitors straight to anonymous Stack checkout", async () => {
    userResponses = [null, anonymousUser];

    const response = await GET(
      new NextRequest("https://cmux.test/api/billing/checkout"),
    );

    expect(response.status).toBe(307);
    expect(response.headers.get("location")).toBe("https://checkout.test/anonymous");
    expect(getUser).toHaveBeenNthCalledWith(1, { or: "return-null" });
    expect(getUser).toHaveBeenNthCalledWith(2, { or: "anonymous" });
    expect(anonymousUser.createCheckoutUrl).toHaveBeenCalledWith({
      productId: "pro",
      returnUrl: "https://cmux.test/api/billing/confirm",
    });
  });

  test("keeps signed-in checkout on the existing Stack user", async () => {
    userResponses = [signedInUser];

    const response = await GET(
      new NextRequest("https://cmux.test/api/billing/checkout"),
    );

    expect(response.status).toBe(307);
    expect(response.headers.get("location")).toBe("https://checkout.test/signed-in");
    expect(getUser).toHaveBeenCalledTimes(1);
    expect(signedInUser.createCheckoutUrl).toHaveBeenCalledWith({
      productId: "pro",
      returnUrl: "https://cmux.test/api/billing/confirm",
    });
  });
});
