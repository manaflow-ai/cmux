// Font family rows (FontPicker): fonts picked lately first, each family drawn in its own face, the
// arrow keys preview the highlighted font live, Return writes it, Escape reverts with no write.
import { afterAll, afterEach, describe, expect, test } from "bun:test";
import { DEFAULT_FONT_ROW, fontFace, fontRows, recentAfterPick, RECENT_FONT_LIMIT } from "./fontPickerModel";
import { installDom } from "./testDom";
import type { Rendered } from "./testing";

const restore = installDom();
afterAll(() => restore());
const { click, fire, ops, renderPage, rowElement, settle } = await import("./testing");

let page: Rendered | null = null;
afterEach(() => {
  page?.unmount();
  page = null;
});

const names = ["Berkeley Mono", "Iosevka", "JetBrains Mono", "Menlo", "SF Mono"];

describe("fontRows", () => {
  test("the default, then recent fonts, then the rest, each once", () => {
    const { rows, recent } = fontRows({ names, recent: ["Menlo", "Iosevka"], query: "" });
    expect(rows).toEqual([DEFAULT_FONT_ROW, "Menlo", "Iosevka", "Berkeley Mono", "JetBrains Mono", "SF Mono"]);
    expect([...recent]).toEqual(["Menlo", "Iosevka"]);
  });

  test("a recent font no longer installed is left out; typing filters both groups and hides the default", () => {
    const { rows } = fontRows({ names, recent: ["Fira Code", "SF Mono"], query: "mono" });
    expect(rows).toEqual(["SF Mono", "Berkeley Mono", "JetBrains Mono"]);
  });

  test("a pick moves the font to the front and the list keeps its limit", () => {
    const many = ["A", "B", "C", "D", "E", "F"];
    expect(recentAfterPick(many, "C")).toEqual(["C", "A", "B", "D", "E", "F"]);
    expect(recentAfterPick(many, "G")).toHaveLength(RECENT_FONT_LIMIT);
    expect(recentAfterPick(many, "G")[0]).toBe("G");
  });

  test("a family name cannot break out of its CSS string", () => {
    expect(fontFace('Evil", serif; x')).toBe('"Evil, serif; x", monospace');
  });
});

describe("FontPicker", () => {
  const open = async () => {
    page = await renderPage({ path: "/settings/appearance" });
    await click(rowElement(page.container, "terminal.fontFamily").querySelector("[data-font-picker]")!);
    return document.querySelector<HTMLElement>(".font-search")!;
  };

  test("every family draws in its own face, recent fonts first with a Recent tag", async () => {
    await open();
    const options = [...document.querySelectorAll<HTMLElement>("[data-font-option]")];
    expect(options[0]!.getAttribute("data-font-option")).toBe("JetBrains Mono");
    expect(options[0]!.querySelector(".font-option-tag")).not.toBeNull();
    expect(options[1]!.querySelector(".font-option-tag")).toBeNull();
    for (const option of options)
      expect(option.querySelector<HTMLElement>(".font-option-name")!.style.fontFamily).toContain(
        option.getAttribute("data-font-option")!,
      );
  });

  test("the arrow keys preview live; Escape reverts without writing", async () => {
    const search = await open();
    await fire(search, "keydown", { key: "ArrowDown" });
    await fire(search, "keydown", { key: "ArrowDown" });
    const previews = ops(page!.provider, "cmux.settings.preview");
    expect(previews.at(-1)).toEqual({ key: "terminal.fontFamily", value: "JetBrains Mono" });
    await fire(search, "keydown", { key: "Escape" });
    expect(ops(page!.provider, "cmux.settings.preview.end")).toEqual([{ key: "terminal.fontFamily" }]);
    expect(ops(page!.provider, "cmux.settings.set")).toEqual([]);
  });

  test("highlighting the default after a preview ends it, so Escape has nothing left to revert", async () => {
    const search = await open();
    await fire(search, "keydown", { key: "ArrowDown" });
    await fire(search, "keydown", { key: "ArrowDown" });
    expect(ops(page!.provider, "cmux.settings.preview").length).toBe(1);
    await fire(search, "keydown", { key: "ArrowUp" });
    expect(ops(page!.provider, "cmux.settings.preview.end")).toEqual([{ key: "terminal.fontFamily" }]);
    await fire(search, "keydown", { key: "Escape" });
    expect(ops(page!.provider, "cmux.settings.preview.end")).toHaveLength(1);
  });

  test("a late save cannot end a newer preview after the picker reopens", async () => {
    const search = await open();
    let resolveSave!: () => void;
    page!.store.set = (() =>
      new Promise<void>((resolve) => (resolveSave = resolve))) as unknown as Rendered["store"]["set"];
    // The first row is the default, which is already in effect; the second is a family to save.
    await fire(search, "keydown", { key: "ArrowDown" });
    await fire(search, "keydown", { key: "ArrowDown" });
    await fire(search, "keydown", { key: "Enter" });
    const button = rowElement(page!.container, "terminal.fontFamily").querySelector<HTMLElement>("[data-font-picker]")!;
    const now = performance.now;
    const later = now.call(performance) + 1000;
    performance.now = () => later;
    try {
      await click(button);
    } finally {
      performance.now = now;
    }
    const reopened = document.querySelector<HTMLElement>(".font-search")!;
    await fire(reopened, "keydown", { key: "ArrowDown" });
    await fire(reopened, "keydown", { key: "ArrowDown" });
    expect(ops(page!.provider, "cmux.settings.preview").length).toBe(2);
    const endsBeforeSave = ops(page!.provider, "cmux.settings.preview.end").length;
    resolveSave();
    await settle();
    expect(ops(page!.provider, "cmux.settings.preview.end").length).toBe(endsBeforeSave);
  });

  test("Return writes the highlighted font, and it leads the list next time", async () => {
    const search = await open();
    for (let step = 0; step < 3; step += 1) await fire(search, "keydown", { key: "ArrowDown" });
    await fire(search, "keydown", { key: "Enter" });
    expect(ops(page!.provider, "cmux.settings.set")).toEqual([{ key: "terminal.fontFamily", value: "Berkeley Mono" }]);
    const button = rowElement(page!.container, "terminal.fontFamily").querySelector<HTMLElement>("[data-font-picker]")!;
    expect(button.textContent).toContain("Berkeley Mono");
    // The button ignores a press right after the list closed (the press that closed it), so the
    // clock moves past that guard before the press.
    const now = performance.now;
    const later = now.call(performance) + 1000;
    performance.now = () => later;
    try {
      await click(button);
    } finally {
      performance.now = now;
    }
    const first = document.querySelector("[data-font-option]");
    expect(first?.getAttribute("data-font-option")).toBe("Berkeley Mono");
  });
});
