// The category jump bar (ICON-PICKER-ALL-EMOJI-AND-SF-SYMBOLS, S3 b): one target per titled grid
// section (emoji groups, symbol categories); a jump makes the section's first cell active and
// returns the header's offset for the grid to scroll to. Alt-Down and Alt-Up jump from the
// search field. Model level: no DOM.
import { describe, expect, test } from "bun:test";
import { decodeEmojiTable, type RawEmojiTable } from "./emojiData";
import raw from "./generated/emoji-data.json";
import { layoutGrid, sectionAt } from "./gridModel";
import { pickerKeyAction } from "./keyboard";
import { PickerStore } from "./store";

const emoji = decodeEmojiTable(raw as RawEmojiTable);
const metrics = { cell: 36, header: 28 };

describe("section anchors", () => {
  const layout = layoutGrid(
    [
      { id: "a", title: "A", items: [1, 2, 3, 4, 5] },
      { id: "empty", title: "E", items: [] },
      { id: "results", title: "", items: [9] },
      { id: "b", title: "B", items: [6, 7] },
    ],
    3,
    metrics,
  );

  test("each titled section with items has its header offset and first item", () => {
    expect(layout.sections).toEqual([
      { id: "a", title: "A", top: 0, first: 0 },
      { id: "b", title: "B", top: 136, first: 6 },
    ]);
  });

  test("the section at a scroll offset is the last one whose header is at or above it", () => {
    expect(sectionAt(layout, 0)).toBe("a");
    expect(sectionAt(layout, 135)).toBe("a");
    expect(sectionAt(layout, 136)).toBe("b");
    expect(sectionAt(layout, 9999)).toBe("b");
    expect(sectionAt(layoutGrid([], 3, metrics), 0)).toBeNull();
  });
});

describe("store jumps", () => {
  const store = () => new PickerStore({ emoji, titles: (id) => `T(${id})` });

  test("emoji tab: one target per group, with its title and a glyph", () => {
    const jumps = store().getSnapshot().jumps;
    expect(jumps.map((jump) => jump.id)).toEqual([...emoji.groups]);
    expect(jumps[0]).toMatchObject({ id: "smileys-emotion", label: "T(smileys-emotion)" });
    expect(jumps.every((jump) => !!jump.glyph)).toBe(true);
  });

  test("a jump activates the section's first cell and returns its header offset", () => {
    const picker = store();
    const top = picker.jump("flags");
    const { layout, active } = picker.getSnapshot();
    const flags = layout.sections.find((section) => section.id === "flags")!;
    expect(top).toBe(flags.top);
    expect(active).toBe(flags.first);
    expect(picker.jump("no-such-section")).toBeNull();
  });

  test("symbol tab: one target per category, drawn with the category's symbol", () => {
    const picker = store();
    picker.configure({
      names: ["folder", "car"],
      categories: [
        { key: "objectsandtools", icon: "folder", members: [0] },
        { key: "transportation", icon: "car.fill", members: [1] },
      ],
    });
    picker.setTab("symbol");
    expect(picker.getSnapshot().jumps).toEqual([
      { id: "symbolCategory.objectsandtools", label: "T(symbolCategory.objectsandtools)", symbol: "folder" },
      { id: "symbolCategory.transportation", label: "T(symbolCategory.transportation)", symbol: "car.fill" },
    ]);
  });

  test("search results have no jump targets", () => {
    const picker = store();
    picker.setQuery("cat");
    expect(picker.getSnapshot().jumps).toEqual([]);
  });

  test("Alt-Down and Alt-Up step through the sections from the active cell", () => {
    const picker = store();
    const [first, second] = picker.getSnapshot().layout.sections;
    expect(picker.jumpBy(1)).toBe(second.top);
    expect(picker.getSnapshot().active).toBe(second.first);
    expect(picker.jumpBy(-1)).toBe(first.top);
    expect(picker.jumpBy(-1)).toBe(first.top);
    const base = { key: "ArrowDown", ctrlKey: false, metaKey: false, altKey: true, shiftKey: false };
    expect(pickerKeyAction(base)).toEqual({ kind: "section", step: 1 });
    expect(pickerKeyAction({ ...base, key: "ArrowUp" })).toEqual({ kind: "section", step: -1 });
  });
});
