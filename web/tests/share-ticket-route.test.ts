import { describe, expect, test } from "bun:test";
import { generateKeyPairSync } from "node:crypto";
import {
  handleShareTicketRequest,
  type ShareTicketRouteDeps,
} from "../app/api/share/[shareId]/ticket/route";
import { mintShareViewerTicket } from "../services/share/ticket";

const SHARE_ID = "AbCdEfGhIjKlMnOpQrSt_-";

function request(origin = "https://cmux.com"): Request {
  return new Request(`https://cmux.com/api/share/${SHARE_ID}/ticket`, {
    method: "POST",
    headers: { origin, "sec-fetch-site": "same-origin", "content-type": "application/json" },
    body: "{}",
  });
}

function deps(overrides: Partial<ShareTicketRouteDeps> = {}): ShareTicketRouteDeps {
  const { privateKey } = generateKeyPairSync("ed25519");
  return {
    verifyRequest: async () => ({
      id: "user-1",
      displayName: "Person",
      primaryEmail: "person@example.com",
      primaryEmailVerified: true,
      billingCustomerType: "user",
      billingTeamId: "user-1",
      selectedTeamId: null,
      teams: [],
      teamIds: [],
      userBillingPlanId: null,
      billingPlanId: null,
    }),
    signingKey: () => privateKey,
    signingKeyId: () => "current",
    socketOrigin: () => "wss://share.cmux.dev",
    mint: mintShareViewerTicket,
    checkRateLimit: async () => ({ rateLimited: false }) as never,
    rateLimitId: () => "share-rule",
    isVercel: () => false,
    ...overrides,
  };
}

describe("share ticket route", () => {
  test("authenticates the browser and returns a no-store socket ticket", async () => {
    const response = await handleShareTicketRequest(request(), SHARE_ID, deps());
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("private, no-store");
    expect(response.headers.get("referrer-policy")).toBe("no-referrer");
    const body = await response.json() as Record<string, unknown>;
    expect(body.socketUrl).toBe(`wss://share.cmux.dev/v1/shares/${SHARE_ID}/socket`);
    expect(body).not.toHaveProperty("accessToken");
  });

  test("rejects cross-site mutation and unauthenticated callers", async () => {
    const crossSite = await handleShareTicketRequest(request("https://attacker.example"), SHARE_ID, deps());
    expect(crossSite.status).toBe(403);
    const unauthorized = await handleShareTicketRequest(request(), SHARE_ID, deps({ verifyRequest: async () => null }));
    expect(unauthorized.status).toBe(401);
  });

  test("fails closed when signing or rate-limit configuration is absent", async () => {
    const noKey = await handleShareTicketRequest(request(), SHARE_ID, deps({ signingKey: () => null }));
    expect(noKey.status).toBe(503);
    const noLimit = await handleShareTicketRequest(request(), SHARE_ID, deps({
      isVercel: () => true,
      rateLimitId: () => undefined,
    }));
    expect(noLimit.status).toBe(503);
  });

  test("requires a verified primary email", async () => {
    const response = await handleShareTicketRequest(request(), SHARE_ID, deps({
      verifyRequest: async () => ({
        ...(await deps().verifyRequest(request()))!,
        primaryEmailVerified: false,
      }),
    }));
    expect(response.status).toBe(403);
  });
});
