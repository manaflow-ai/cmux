import { describe, expect, it } from "vitest";
import { colorsToCursorOptionsPatch, colorsToThemePatch } from "../src/lib/terminalColors";

describe("effective terminal colors", () => {
  it("returns no patch when an older server omits colors", () => {
    expect(colorsToThemePatch(undefined)).toBeNull();
    expect(colorsToThemePatch(null)).toBeNull();
  });

  it("maps only present non-null special colors", () => {
    expect(colorsToThemePatch({ bg: "#1d1f21", cursor: null })).toEqual({
      background: "#1d1f21",
    });
  });

  it("maps the full effective color set without indexed palette keys", () => {
    const colors = {
      fg: "#d8d9da",
      bg: "#131415",
      cursor: "#f0f0f0",
      selection_bg: "#334455",
      selection_fg: "#ffffff",
    } as const;
    const expected = {
      foreground: "#d8d9da",
      background: "#131415",
      cursor: "#f0f0f0",
      selectionBackground: "#334455",
      selectionForeground: "#ffffff",
    };

    expect(colorsToThemePatch(colors)).toEqual(expected);
  });

  it("returns the same harmless patch when colors-changed repeats current colors", () => {
    const colors = { fg: "#d8d9da", bg: "#131415" } as const;
    expect(colorsToThemePatch(colors)).toEqual(colorsToThemePatch(colors));
  });
});

describe("effective terminal cursor options", () => {
  it("leaves current options untouched for null fields", () => {
    expect(colorsToCursorOptionsPatch({ cursor_style: null, cursor_blink: null })).toEqual({});
  });

  it("maps a full cursor option set", () => {
    expect(colorsToCursorOptionsPatch({ cursor_style: "bar", cursor_blink: false })).toEqual({
      cursorStyle: "bar",
      cursorBlink: false,
    });
  });

  it("ignores invalid wire values", () => {
    expect(colorsToCursorOptionsPatch({ cursor_style: "beam", cursor_blink: "true" })).toEqual({});
  });
});
