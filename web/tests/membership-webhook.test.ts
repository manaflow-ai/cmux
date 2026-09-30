import { describe, expect, test } from "bun:test";
import { createHmac } from "node:crypto";
import { createStackMembershipWebhookHandler } from "../services/teams/membershipWebhook";

const secret = `whsec_${Buffer.from("membership-test-secret").toString("base64")}`;
const body = JSON.stringify({
  type: "team_membership.created",
  data: { team_id: "team_1", user_id: "user_1" },
});

function request(overrides: Record<string, string> = {}, payload = body) {
  const id = overrides["svix-id"] ?? "msg_1";
  const timestamp = overrides["svix-timestamp"] ?? "1700000000";
  const signature = createHmac("sha256", Buffer.from("membership-test-secret"))
    .update(`${id}.${timestamp}.${payload}`)
    .digest("base64");
  return new Request("https://example.test/api/webhooks/stack", {
    method: "POST",
    body: payload,
    headers: {
      "svix-id": id,
      "svix-timestamp": timestamp,
      "svix-signature": `v1,${signature}`,
      ...overrides,
    },
  });
}

describe("Stack membership webhook", () => {
  test("accepts a valid signed event and reconciles it", async () => {
    process.env.STACK_TEAM_WEBHOOK_SECRET = secret;
    const calls: string[][] = [];
    const handler = createStackMembershipWebhookHandler({
      now: () => 1700000000,
      reconcile: async (...args) => calls.push(args),
    });
    const response = await handler(request());
    expect(response.status).toBe(200);
    expect(calls).toEqual([["team_1", "user_1", "msg_1"]]);
  });

  test("rejects bad, missing, and stale signatures", async () => {
    process.env.STACK_TEAM_WEBHOOK_SECRET = secret;
    const handler = createStackMembershipWebhookHandler({ now: () => 1700000000, reconcile: async () => {} });
    expect((await handler(request({ "svix-signature": "v1,bad" }))).status).toBe(401);
    expect((await handler(new Request("https://example.test", { method: "POST", body }))).status).toBe(401);
    expect((await handler(request({ "svix-timestamp": "1699990000" }))).status).toBe(401);
  });

  test("rejects a wrong payload", async () => {
    process.env.STACK_TEAM_WEBHOOK_SECRET = secret;
    const handler = createStackMembershipWebhookHandler({ now: () => 1700000000, reconcile: async () => {} });
    const response = await handler(request({}, JSON.stringify({ type: "team.deleted", data: {} })));
    expect(response.status).toBe(400);
  });
});
