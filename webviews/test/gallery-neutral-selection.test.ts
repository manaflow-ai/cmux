// The test window's selection follows `appearance.selection` as the app's does (cmux-theme-tokens
// tokens.rs: `neutral` keeps the neutral fill whatever the accent). The gallery's copy of the derive
// took the accent tint whenever there was an accent, so a neutral look's screenshots showed an
// accent-tinted row and tab (RFD 0033 strict fix 4).
import { describe, expect, test } from "bun:test";
import { schemeFromThemeFile } from "../dev-server/goldenLooks";
import { deriveTokens, GHOSTTY_DEFAULT } from "../src/gallery/theme/tokens";

const withAccent = { ...GHOSTTY_DEFAULT, accent: "blue" as const };

describe("appearance.selection in the test window", () => {
  test("neutral keeps the neutral fill under an accent", () => {
    const accent = deriveTokens(withAccent);
    const neutral = deriveTokens({ ...withAccent, selection: "neutral" });
    const noAccent = deriveTokens({ ...GHOSTTY_DEFAULT, accent: "neutral" });
    expect(accent.selectionFill).not.toEqual(noAccent.selectionFill);
    expect(neutral.selectionFill).toEqual(noAccent.selectionFill);
    expect(neutral.secondarySelectionFill).toEqual(noAccent.secondarySelectionFill);
    expect(neutral.accent).toEqual(accent.accent);
  });

  test("accent, or no setting, keeps the accent tint", () => {
    expect(deriveTokens({ ...withAccent, selection: "accent" }).selectionFill).toEqual(
      deriveTokens(withAccent).selectionFill,
    );
  });

  test("a look's theme file carries the setting to the golden", () => {
    expect(schemeFromThemeFile({ "appearance.selection": "neutral" }, "x").selection).toBe("neutral");
    expect(schemeFromThemeFile({ "appearance.selection": "loud" }, "x").selection).toBeUndefined();
  });
});
