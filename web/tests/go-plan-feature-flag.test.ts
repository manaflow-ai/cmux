import { describe, expect, test } from "bun:test";
import { FEATURE_FLAGS } from "../app/lib/feature-flags";
import { isGoPlanEnabled, isWebPlusPlanEnabled } from "../services/billing/goPlanFlag";

const response = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status });

describe("Go rollout flag", () => {
  test("uses the remote PostHog value when present", async () => {
    const enabled = await isGoPlanEnabled("test-user", async (input, init) => {
      expect(input).toContain("/flags/");
      expect(init?.method).toBe("POST");
      return response({ flags: { [FEATURE_FLAGS.goPlan.key]: { enabled: true } } });
    });
    expect(enabled).toBe(true);
  });
  test("fails closed when the remote flag is false or unavailable", async () => {
    expect(await isGoPlanEnabled("test-user", async () => response({ flags: { [FEATURE_FLAGS.goPlan.key]: { enabled: false } } }))).toBe(false);
    expect(await isGoPlanEnabled("test-user", async () => response({}, 503))).toBe(false);
  });
});

// Releasing web Plus must not accidentally release App Store Go.
test("web Plus is available while App Store Go still honors its release flag", async () => {
  expect(await isWebPlusPlanEnabled("test-user")).toBe(true);
  expect(await isGoPlanEnabled("test-user", async () => response({}, 503))).toBe(false);
});
