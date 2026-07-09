import { describe, expect, test } from "bun:test";

import PrivacyPolicyPage from "../app/[locale]/(legal)/privacy-policy/page";

describe("privacy policy page", () => {
  test("redirects non-default locale requests to the canonical policy", async () => {
    try {
      await PrivacyPolicyPage({
        params: Promise.resolve({ locale: "ja" }),
      });
      throw new Error("expected privacy policy redirect");
    } catch (error) {
      const digest = (error as { digest?: unknown }).digest;
      expect(String(digest)).toContain("NEXT_REDIRECT");
      expect(String(digest)).toContain("/privacy-policy");
    }
  });
});
