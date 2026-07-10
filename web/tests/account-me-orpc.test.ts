import { describe, expect, test } from "bun:test";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { call } from "@orpc/server";

import { accountMeProcedure } from "../orpc/server/account/me";
import { generateOpenAPIDocument } from "../orpc/server/openapi";
import { resolveProPlanStatus } from "../services/billing/pro";

// The two checked-in specs the Swift client and /api/openapi.json ship must
// stay identical to what the router generates. Resolve relative to this test
// file so the paths hold regardless of the process cwd.
const CHECKED_IN_SPECS = [
  "../openapi/openapi.json",
  "../../Packages/Shared/CmuxAPIClient/Sources/CmuxAPIClient/openapi.json",
] as const;

// Drives the real resolveProPlanStatus (no module mocks, so it can't leak into
// other test files). Plan resolution is Stripe-backed: an id-less fake user
// short-circuits the Stripe-subscription lookup to Free without touching a
// database, and the Pro path injects the subscription query directly.
function fakeUser(opts: { email: string | null }) {
  return {
    primaryEmail: opts.email,
    clientReadOnlyMetadata: {},
    update: async () => undefined,
  };
}

function context(user: unknown) {
  return { request: new Request("http://localhost/api/rpc"), user } as never;
}

describe("account.me", () => {
  test("returns the Free plan for a user with no Stripe subscription", async () => {
    const result = await call(accountMeProcedure, undefined, {
      context: context(fakeUser({ email: "a@example.com" })),
    });
    expect(result).toEqual({
      userId: "",
      email: "a@example.com",
      planId: "free",
      isPro: false,
      billingManagement: "none",
    });
  });

  test("returns the Free plan and an empty email for an email-less non-subscriber", async () => {
    const result = await call(accountMeProcedure, undefined, {
      context: context(fakeUser({ email: null })),
    });
    expect(result.planId).toBe("free");
    expect(result.isPro).toBe(false);
    expect(result.email).toBe("");
    expect(result.billingManagement).toBe("none");
  });

  test("resolves Stripe-managed Pro and syncs plan metadata for an active subscription", async () => {
    const updates: unknown[] = [];
    const user = {
      id: "user-1",
      clientReadOnlyMetadata: {},
      update: async (options: unknown) => {
        updates.push(options);
      },
    };
    const status = await resolveProPlanStatus(user, {
      hasActiveStripeSubscription: async (stackUserId) => stackUserId === "user-1",
    });
    expect(status.planId).toBe("pro");
    expect(status.isPro).toBe(true);
    expect(status.billingManagement).toBe("stripe");
    // The read-time reconciliation must write cmuxPlan: "pro" back to Stack.
    expect(updates).toEqual([{ clientReadOnlyMetadata: { cmuxPlan: "pro" } }]);
  });

  test("rejects unauthenticated callers before resolving a plan", async () => {
    await expect(
      call(accountMeProcedure, undefined, { context: context(null) }),
    ).rejects.toThrow();
  });

  test("OpenAPI document advertises account.me at GET /account/me on /api/v1", async () => {
    const doc = await generateOpenAPIDocument();
    const operation = (doc.paths?.["/account/me"] as { get?: { operationId?: string } } | undefined)
      ?.get;
    expect(operation?.operationId).toBe("account.me");
    expect(doc.servers?.[0]?.url).toBe("/api/v1");
  });

  test("both checked-in specs are byte-identical to the generated document", async () => {
    const doc = await generateOpenAPIDocument();
    // Must match the regeneration procedure exactly (2-space indent + trailing
    // newline) so a stale commit fails here instead of at Swift decode time.
    const generated = JSON.stringify(doc, null, 2) + "\n";
    for (const relative of CHECKED_IN_SPECS) {
      const path = fileURLToPath(new URL(relative, import.meta.url));
      const onDisk = await readFile(path, "utf8");
      // Equality failure names the file via the diff; keep the spec regen
      // procedure in mind when this trips (see web PR instructions).
      expect(onDisk).toBe(generated);
    }
  });
});
