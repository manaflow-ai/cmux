import { describe, expect, test } from "bun:test";

import {
  analyticsPropertiesContainSharePath,
  containsPrivateSharePath,
  privateSharePageMetadata,
  shouldInitializeAnalytics,
} from "../services/analytics/sharePrivacy";

describe("share analytics privacy", () => {
  test("prevents invitation URLs from entering referrers or search indexes", () => {
    expect(privateSharePageMetadata).toEqual({
      referrer: "no-referrer",
      robots: { index: false, follow: false },
    });
  });

  test("recognizes localized and unlocalized invitation URLs", () => {
    expect(containsPrivateSharePath("/share/code1234")).toBe(true);
    expect(
      containsPrivateSharePath(
        "https://cmux.com/ja/share/AbCdEf0123456789012345?from=sign-in",
      ),
    ).toBe(true);
    expect(containsPrivateSharePath("/share/short")).toBe(false);
    expect(containsPrivateSharePath("/docs/multiplayer-share")).toBe(false);
    expect(shouldInitializeAnalytics("/ja/share/code12345678")).toBe(false);
    expect(shouldInitializeAnalytics("/docs/multiplayer-share")).toBe(true);
  });

  test("finds share codes in pageview and referrer properties", () => {
    expect(
      analyticsPropertiesContainSharePath({
        $current_url: "https://cmux.com/en/share/code12345678",
      }),
    ).toBe(true);
    expect(
      analyticsPropertiesContainSharePath({
        $referrer: "https://cmux.com/share/code12345678",
      }),
    ).toBe(true);
    expect(
      analyticsPropertiesContainSharePath({
        $current_url: "https://cmux.com/docs/multiplayer-share",
      }),
    ).toBe(false);
  });
});
