import { describe, expect, test } from "bun:test";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { call } from "@orpc/server";

import { accountMeProcedure } from "../orpc/server/account/me";
import { generateOpenAPIDocument } from "../orpc/server/openapi";
import { PRO_PRODUCT_ID } from "../services/billing/pro";

// The two checked-in specs the Swift client and /api/openapi.json ship must
// stay identical to what the router generates. Resolve relative to this test
// file so the paths hold regardless of the process cwd.
const CHECKED_IN_SPECS = [
  "../openapi/openapi.json",
  "../../Packages/Shared/CmuxAPIClient/Sources/CmuxAPIClient/openapi.json",
] as const;

// Drives the real resolveProPlanStatus (no module mocks, so it can't leak into
// other test files). The fake user carries no `id`, so the Stripe-subscription
// lookup short-circuits to false and no database is touched; the Stack product
// list alone decides Pro vs Free.
type FakeProduct = {
  id: string;
  subscription: { currentPeriodEnd: Date | null } | null;
  quantity: number;
};

function productsPage(items: FakeProduct[]) {
  const page = [...items] as FakeProduct[] & { nextCursor: string | null };
  page.nextCursor = null;
  return page;
}

function fakeUser(opts: { email: string | null; pro: boolean }) {
  return {
    primaryEmail: opts.email,
    clientReadOnlyMetadata: {},
    listProducts: async () =>
      productsPage(
        opts.pro ? [{ id: PRO_PRODUCT_ID, subscription: null, quantity: 1 }] : [],
      ),
    update: async () => undefined,
  };
}

function context(user: unknown) {
  return { request: new Request("http://localhost/api/rpc"), user } as never;
}

describe("account.me", () => {
  test("returns the Pro plan (external billing) for a Stack-Pro user", async () => {
    const result = await call(accountMeProcedure, undefined, {
      context: context(fakeUser({ email: "a@example.com", pro: true })),
    });
    expect(result).toEqual({
      userId: "",
      email: "a@example.com",
      planId: "pro",
      isPro: true,
      billingManagement: "external",
    });
  });

  test("returns the Free plan and an empty email for an email-less non-subscriber", async () => {
    const result = await call(accountMeProcedure, undefined, {
      context: context(fakeUser({ email: null, pro: false })),
    });
    expect(result.planId).toBe("free");
    expect(result.isPro).toBe(false);
    expect(result.email).toBe("");
    expect(result.billingManagement).toBe("none");
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
