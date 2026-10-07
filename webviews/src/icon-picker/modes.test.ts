// SF Symbol rendering modes (ICON-PICKER-ALL-EMOJI-AND-SF-SYMBOLS, S3 c): the Symbols tab shows
// symbols monochrome (the host's template image, tinted by the page as a mask), hierarchical (a
// layered template the page tints the same way, in the theme color) or multicolor (an image in the symbol's own colors,
// for symbols that have them; the others stay monochrome). The mode is remembered with the prefs.
import { describe, expect, test } from "bun:test";
import { decodeEmojiTable, type RawEmojiTable } from "./emojiData";
import raw from "./generated/emoji-data.json";
import { decodePrefs, type PickerPrefs } from "./recents";
import { PickerStore } from "./store";
import { symbolRendering } from "./symbols";

const emoji = decodeEmojiTable(raw as RawEmojiTable);

describe("symbol rendering modes", () => {
  test("multicolor applies only to symbols that have it; hierarchical to every symbol", () => {
    expect(symbolRendering("monochrome", true)).toBe("monochrome");
    expect(symbolRendering("hierarchical", false)).toBe("hierarchical");
    expect(symbolRendering("multicolor", true)).toBe("multicolor");
    expect(symbolRendering("multicolor", false)).toBe("monochrome");
  });

  test("the mode is saved with the prefs and restored", async () => {
    const saved: PickerPrefs[] = [];
    const picker = new PickerStore({
      emoji,
      titles: (id) => id,
      prefs: {
        load: () => decodePrefs({ tone: 0, recents: [], symbolMode: "hierarchical" }),
        save: (p) => saved.push(p),
      },
    });
    expect(picker.getSnapshot().symbolMode).toBe("hierarchical");
    picker.setSymbolMode("multicolor");
    expect(picker.getSnapshot().symbolMode).toBe("multicolor");
    expect(saved.at(-1)?.symbolMode).toBe("multicolor");
  });

  test("decoding keeps a known mode and drops anything else", () => {
    expect(decodePrefs({ symbolMode: "multicolor" }).symbolMode).toBe("multicolor");
    expect(decodePrefs({ symbolMode: "rainbow" }).symbolMode).toBeUndefined();
    expect(new PickerStore({ emoji, titles: (id) => id }).getSnapshot().symbolMode).toBe("monochrome");
  });
});
