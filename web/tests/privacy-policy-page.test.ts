import { describe, expect, test } from "bun:test";

import { privacyPolicyRedirectPath } from "../app/[locale]/(legal)/privacy-policy/page";

describe("privacy policy page", () => {
  test("routes non-default locale requests to the canonical policy", () => {
    expect(privacyPolicyRedirectPath("en")).toBeNull();
    expect(privacyPolicyRedirectPath("ja")).toBe("/privacy-policy");
  });
});
