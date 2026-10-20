import { describe, expect, it } from "vitest";
import {
  colorsToCursorOptionsPatch,
  colorsToDynamicColorSequence,
  colorsToPaletteSequence,
  colorsToSelectionThemePatch,
} from "../src/lib/terminalColors";

describe("effective terminal colors", () => {
  it("returns no patch when an older server omits colors", () => {
    expect(colorsToSelectionThemePatch(undefined)).toBeNull();
    expect(colorsToSelectionThemePatch(null)).toBeNull();
    expect(colorsToDynamicColorSequence(undefined)).toBeNull();
  });

  it("maps only present non-null special colors", () => {
    expect(colorsToSelectionThemePatch({ selection_bg: "#1d1f21", cursor: null })).toEqual({
      selectionBackground: "#1d1f21",
    });
  });

  it("maps dynamic colors to OSC without changing theme restore defaults", () => {
    const colors = {
      fg: "#d8d9da",
      bg: "#131415",
      cursor: "#f0f0f0",
      selection_bg: "#334455",
      selection_fg: "#ffffff",
    } as const;
    expect(colorsToDynamicColorSequence(colors)).toBe(
      "\x1b]10;#d8d9da\x1b\\"
      + "\x1b]11;#131415\x1b\\"
      + "\x1b]12;#f0f0f0\x1b\\",
    );
    expect(colorsToSelectionThemePatch(colors)).toEqual({
      selectionBackground: "#334455",
      selectionForeground: "#ffffff",
    });
  });

  it("builds a deterministic reset and sparse OSC 4 sequence", () => {
    const sequence = colorsToPaletteSequence({
      palette: {
        "1": "#112233",
        "15": "#445566",
        "16": "#778899",
        "255": "#aabbcc",
        "-1": "#000000",
        "256": "#ffffff",
        invalid: "#123456",
      },
    });

    expect(sequence).toBe(
      "\x1b]104\x1b\\"
      + "\x1b]4;1;#112233\x1b\\"
      + "\x1b]4;15;#445566\x1b\\"
      + "\x1b]4;16;#778899\x1b\\"
      + "\x1b]4;255;#aabbcc\x1b\\",
    );
    expect(colorsToPaletteSequence({})).toBeNull();
  });

  it("returns the same harmless sequences when colors-changed repeats current colors", () => {
    const colors = { fg: "#d8d9da", bg: "#131415" } as const;
    expect(colorsToDynamicColorSequence(colors)).toEqual(colorsToDynamicColorSequence(colors));
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
