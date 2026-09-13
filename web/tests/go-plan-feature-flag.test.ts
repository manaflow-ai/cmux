import { describe, expect, test } from "bun:test";
import { FEATURE_FLAGS } from "../app/lib/feature-flags";
import { isGoPlanEnabled } from "../services/billing/goPlanFlag";

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
