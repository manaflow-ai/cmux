import { beforeEach, describe, expect, mock, test } from "bun:test";
import { NextRequest } from "next/server";

const teamCustomer = {
  id: "team-signed-in",
  createCheckoutUrl: mock(async () => "https://checkout.test/team"),
};
const signedInUser = {
  id: "user-signed-in",
  createCheckoutUrl: mock(async () => "https://checkout.test/signed-in"),
  listProducts: mock(async () => emptyProductsPage()),
  update: mock(async () => undefined),
  selectedTeam: null as null | typeof teamCustomer,
};
const anonymousUser = {
  id: "user-anonymous",
  isAnonymous: true,
  createCheckoutUrl: mock(async () => "https://checkout.test/anonymous"),
  listProducts: mock(async () => emptyProductsPage()),
  update: mock(async () => undefined),
};

let userResponses: unknown[] = [];
const getUser = mock(async () => userResponses.shift() ?? null);

mock.module("../app/lib/stack", () => ({
  getStackServerApp: () => ({ getUser }),
  isStackConfigured: () => true,
  stackServerApp: { getUser },
}));

const { GET } = await import("../app/api/billing/checkout/route");

describe("billing checkout route", () => {
  beforeEach(() => {
    getUser.mockClear();
    signedInUser.createCheckoutUrl.mockClear();
    signedInUser.listProducts.mockClear();
    signedInUser.update.mockClear();
    teamCustomer.createCheckoutUrl.mockClear();
    anonymousUser.createCheckoutUrl.mockClear();
    anonymousUser.listProducts.mockClear();
    anonymousUser.update.mockClear();
    signedInUser.createCheckoutUrl.mockResolvedValue("https://checkout.test/signed-in");
    signedInUser.listProducts.mockResolvedValue(emptyProductsPage());
    signedInUser.update.mockResolvedValue(undefined);
    teamCustomer.createCheckoutUrl.mockResolvedValue("https://checkout.test/team");
    anonymousUser.createCheckoutUrl.mockResolvedValue("https://checkout.test/anonymous");
    anonymousUser.listProducts.mockResolvedValue(emptyProductsPage());
    anonymousUser.update.mockResolvedValue(undefined);
    signedInUser.selectedTeam = null;
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
    expect(signedInUser.listProducts).not.toHaveBeenCalled();
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

function emptyProductsPage() {
  return Object.assign([], { nextCursor: null });
}
