import { describe, expect, test } from "bun:test";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { call } from "@orpc/server";

import { accountMeProcedure } from "../orpc/server/account/me";
import { generateOpenAPIDocument } from "../orpc/server/openapi";

// The two checked-in specs the Swift client and /api/openapi.json ship must
// stay identical to what the router generates. Resolve relative to this test
// file so the paths hold regardless of the process cwd.
const CHECKED_IN_SPECS = [
  "../openapi/openapi.json",
  "../../Packages/Shared/CmuxAPIClient/Sources/CmuxAPIClient/openapi.json",
] as const;

// Drives the real resolveProPlanStatus with no module mocks, so nothing leaks
// into other test files. Pro is resolved from Stripe subscriptions; the fake
// user carries no `id`, so that lookup short-circuits to false without touching
// a database, and account.me maps the resulting Free plan onto its response.
function context(user: unknown) {
  return { request: new Request("http://localhost/api/rpc"), user } as never;
}

function fakeUser(email: string | null) {
  return {
    primaryEmail: email,
    clientReadOnlyMetadata: {},
    update: async () => undefined,
  };
}

describe("account.me", () => {
  test("maps the resolved plan and email onto the response for a non-subscriber", async () => {
    const result = await call(accountMeProcedure, undefined, {
      context: context(fakeUser("a@example.com")),
    });
    expect(result).toEqual({
      userId: "",
      email: "a@example.com",
      planId: "free",
      isPro: false,
      billingManagement: "none",
    });
  });

  test("defaults an absent email to an empty string", async () => {
    const result = await call(accountMeProcedure, undefined, {
      context: context(fakeUser(null)),
    });
    expect(result.email).toBe("");
    expect(result.planId).toBe("free");
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
