import { beforeEach, describe, expect, test, vi } from "vitest";
import { convexTest } from "convex-test";
import schema from "./schema";
import { modules } from "./test.setup";
import { api, internal } from "./_generated/api";

const TEAM_ID = "123e4567-e89b-12d3-a456-426614170010";

describe("github_app internal mutations and auth mint state", () => {
  beforeEach(() => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2024-01-01T00:00:00Z"));
  });

  test("recordWebhookDelivery idempotency + provider connection upsert/deactivate + install state", async () => {
    const t = convexTest(schema, modules);
    const userId = "u1";
    await t.run(async (ctx) => {
      const now = Date.now();
      await ctx.db.insert("teamMemberships", { teamId: TEAM_ID, userId, createdAt: now, updatedAt: now });
      await ctx.db.insert("teams", { teamId: TEAM_ID, createdAt: now, updatedAt: now });
    });
    const asUser = t.withIdentity({ subject: userId });

    // recordWebhookDelivery
    const r1 = await t.mutation(internal.github_app.recordWebhookDelivery, { provider: "github", deliveryId: "d1", payloadHash: "h1" });
    expect(r1.created).toBe(true);
    const r2 = await t.mutation(internal.github_app.recordWebhookDelivery, { provider: "github", deliveryId: "d1", payloadHash: "h1" });
    expect(r2.created).toBe(false);

    // upsertProviderConnectionFromInstallation (insert + update)
    const _id = await t.mutation(internal.github_app.upsertProviderConnectionFromInstallation, { installationId: 42, accountLogin: "acme", accountType: "Organization" });
    await t.mutation(internal.github_app.upsertProviderConnectionFromInstallation, { installationId: 42, accountLogin: "acme-inc", isActive: true });
    // deactivate
    const deact = await t.mutation(internal.github_app.deactivateProviderConnection, { installationId: 42 });
    expect(deact.ok).toBe(true);

    // mint/consume install state
    const minted = await asUser.mutation(api.github_app.mintInstallState, { teamSlugOrId: TEAM_ID });
    expect(typeof minted.state).toBe("string");
    // Extract nonce to find row
    const parts = minted.state.split(".");
    const payload = JSON.parse(Buffer.from(parts[1], "base64url").toString("utf8"));
    const nonce = payload.nonce as string;
    const row = await t.query(internal.github_app.getInstallStateByNonce, { nonce });
    expect(row?.status).toBe("pending");
    const consumed = await t.mutation(internal.github_app.consumeInstallState, { nonce });
    expect(consumed.ok).toBe(true);
  });
});
