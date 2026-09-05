import { describe, expect, it } from "bun:test";
import { compatibilityProtectionHeaders } from "../src/compatibility";

describe("compatibility upstream protection", () => {
  it("adds the bypass only for HTTPS Vercel origins", () => {
    expect(compatibilityProtectionHeaders(
      "https://cmux-staging-jnyr2bt99-manaflow.vercel.app",
      "staging-secret",
    )).toEqual({ "x-vercel-protection-bypass": "staging-secret" });
    expect(compatibilityProtectionHeaders(
      "https://cmux-staging.vercel.app/",
      " staging-secret ",
    )).toEqual({ "x-vercel-protection-bypass": "staging-secret" });
  });

  it("does not leak the secret to custom, HTTP, malformed, or empty origins", () => {
    for (const origin of [
      "https://example.com",
      "http://cmux-staging.vercel.app",
      "https://vercel.app",
      "not a URL",
    ]) {
      expect(compatibilityProtectionHeaders(origin, "staging-secret")).toEqual({});
    }
    expect(compatibilityProtectionHeaders("https://cmux-staging.vercel.app", " "))
      .toEqual({});
  });
});
