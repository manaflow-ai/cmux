import { beforeEach, describe, expect, mock, test } from "bun:test";
import { NextRequest } from "next/server";

const teamCustomer = {
  id: "team-signed-in",
  createCheckoutUrl: mock(async () => "https://checkout.test/team"),
};
const signedInUser = {
  id: "user-signed-in",
  createCheckoutUrl: mock(async () => "https://checkout.test/signed-in"),
  selectedTeam: null as null | typeof teamCustomer,
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
  getStackServerApp: () => ({ getUser }),
  isStackConfigured: () => true,
  stackServerApp: { getUser },
}));

mock.module("../services/billing/pro", () => ({
  PRO_PRODUCT_ID: "pro",
  TEAM_PRODUCT_ID: "team",
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
    teamCustomer.createCheckoutUrl.mockClear();
    anonymousUser.createCheckoutUrl.mockClear();
    signedInUser.createCheckoutUrl.mockResolvedValue("https://checkout.test/signed-in");
    teamCustomer.createCheckoutUrl.mockResolvedValue("https://checkout.test/team");
    anonymousUser.createCheckoutUrl.mockResolvedValue("https://checkout.test/anonymous");
    signedInUser.selectedTeam = null;
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

  test("routes team checkout through the team Stack product", async () => {
    signedInUser.selectedTeam = teamCustomer;
    userResponses = [signedInUser];

    const response = await GET(
      new NextRequest("https://cmux.test/api/billing/checkout?plan=team"),
    );

    expect(response.status).toBe(307);
    expect(response.headers.get("location")).toBe("https://checkout.test/team");
    expect(hasActiveProSubscription).not.toHaveBeenCalled();
    expect(signedInUser.createCheckoutUrl).not.toHaveBeenCalled();
    expect(teamCustomer.createCheckoutUrl).toHaveBeenCalledWith({
      productId: "team",
      returnUrl: "https://cmux.test/pricing?welcome=team",
    });
  });

  test("rejects unknown checkout plans", async () => {
    const response = await GET(
      new NextRequest("https://cmux.test/api/billing/checkout?plan=enterprise"),
    );

    expect(response.status).toBe(307);
    expect(response.headers.get("location")).toBe(
      "https://cmux.test/pricing?billing=invalid_plan",
    );
    expect(getUser).not.toHaveBeenCalled();
  });
});
