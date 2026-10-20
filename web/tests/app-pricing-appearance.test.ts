import { describe, expect, test } from "bun:test";

import {
  appPricingContrastAdjustedAccent,
  appPricingTheme,
} from "../app/app-pricing/appearance";

describe("app pricing contrast-adjusted accent", () => {
  test("keeps cmux blue when it already clears the small-text threshold", () => {
    expect(appPricingContrastAdjustedAccent("#0091ff", "#0a0a0a")).toBe(
      "#0091ff",
    );
    expect(appPricingContrastAdjustedAccent("#0088ff", "#171717")).toBe(
      "#0088ff",
    );
  });

  test("makes the smallest dark or light adjustment needed for the background", () => {
    expect(appPricingContrastAdjustedAccent("#0088ff", "#fdf6e3")).toBe(
      "#0071D5",
    );
    expect(appPricingContrastAdjustedAccent("#0088ff", "#4a4543")).toBe(
      "#6BB9FF",
    );
  });

  test("uses RGB distance when both contrast directions are readable", () => {
    expect(appPricingContrastAdjustedAccent("#000040", "#8060D0")).toBe(
      "#000000",
    );
  });

  test("derives separate canvas and selected-button tokens from Ghostty colors", () => {
    const theme = appPricingTheme({
      appearance: "light",
      background: "#fdf6e3",
      foreground: "#4a4543",
      accent: "#0088ff",
    });

    expect(theme.accent).toBe("#0088ff");
    expect(theme.accentOnBackground).toBe("#0071D5");
    expect(theme.accentOnForeground).toBe("#6BB9FF");
  });

  test("accepts native precomputed tokens for first-paint parity", () => {
    const theme = appPricingTheme({
      appearance: "light",
      background: "#fdf6e3",
      foreground: "#4a4543",
      accent: "#0088ff",
      accent_on_background: "#123456",
      accent_on_foreground: "#abcdef",
    });

    expect(theme.accentOnBackground).toBe("#123456");
    expect(theme.accentOnForeground).toBe("#abcdef");
  });

  test("rejects translucent backgrounds that cannot be contrast-checked", () => {
    const theme = appPricingTheme({
      appearance: "dark",
      background: "#FFFFFF00",
      accent: "#0088ff",
    });

    expect(theme.background).toBe("#272822");
    expect(theme.accentOnBackground).toBe("#0F8FFF");
  });
});
