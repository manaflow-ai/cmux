// The App Font (appearance.appFont). Leo, 2026-11-08: "there's no whole app font change thing ... i
// wanna just be able to see different fonts just like how i can see different themes as preview". Its
// picker lists every installed family (ui_font_families, proportional ones too), each drawn in its own
// face over the system font; the highlighted one previews live in the whole app, as the theme picker
// does, and its sample draws interface text in the picked family.
import { afterAll, afterEach, describe, expect, test } from "bun:test";
import { UI_FONT_VALIDATION, uiFontFace } from "./fontPickerModel";
import { FONT_PREVIEWS, UI_SPECIMEN, familyStack } from "./fontPreviewModel";
import { installDom } from "./testDom";
import type { Rendered } from "./testing";
import { fontNames, validate } from "./validate";
import { rowsByKey } from "./schema";

const restore = installDom();
afterAll(() => restore());
const { click, fire, ops, renderPage, rowElement } = await import("./testing");

const KEY = "appearance.appFont";
let page: Rendered | null = null;
afterEach(() => {
  page?.unmount();
  page = null;
});

describe("App Font model", () => {
  const domains = { font_families: ["Menlo"], ui_font_families: ["Avenir Next", "Menlo"] };

  test("the App Font takes any installed family; the other font rows the fixed-pitch ones", () => {
    expect(fontNames(UI_FONT_VALIDATION, domains)).toEqual(["Avenir Next", "Menlo"]);
    expect(fontNames("domain:font_family", domains)).toEqual(["Menlo"]);
    const row = rowsByKey.get(KEY)!;
    expect(row.validation).toBe(UI_FONT_VALIDATION);
    expect(validate(row, "Avenir Next", domains)).toBeNull();
    expect(validate(row, "Comic Neue", domains)).toBe("unknown font family");
  });

  test("a family falls back to the system face, never to a fixed-pitch one, and cannot leave its string", () => {
    expect(uiFontFace("Avenir Next")).toBe('"Avenir Next", -apple-system, BlinkMacSystemFont, system-ui, sans-serif');
    expect(uiFontFace('Evil", serif; x')).toStartWith('"Evil, serif; x", -apple-system');
    expect(familyStack(null, "text")).toContain("system-ui");
    expect(familyStack("Georgia", "text")).toBe(uiFontFace("Georgia"));
  });

  test("its sample draws interface text at the Text Size", () => {
    expect(FONT_PREVIEWS[KEY]).toEqual({
      kind: "family",
      size: "appearance.metrics.chromeFontSize",
      fallback: null,
      specimen: "text",
    });
  });
});

describe("App Font picker", () => {
  const open = async (values: Record<string, unknown> = {}) => {
    page = await renderPage({ path: "/settings/appearance", mock: { values } });
    await click(rowElement(page.container, KEY).querySelector("[data-font-picker]")!);
    return document.querySelector<HTMLElement>(".font-search")!;
  };

  test("lists every installed family, proportional ones too, each in its own face over the system font", async () => {
    await open();
    const options = [...document.querySelectorAll<HTMLElement>("[data-font-option]")];
    const listed = options.map((option) => option.getAttribute("data-font-option"));
    expect(listed).toContain("Avenir Next");
    expect(listed).toContain("Georgia");
    for (const option of options) {
      const face = option.querySelector<HTMLElement>(".font-option-name")!.style.fontFamily;
      expect(face).toContain(option.getAttribute("data-font-option")!);
      expect(face).not.toContain("monospace");
    }
  });

  test("the arrow keys preview a family in the whole app; Return writes it", async () => {
    const search = await open();
    await fire(search, "keydown", { key: "ArrowDown" });
    await fire(search, "keydown", { key: "ArrowDown" });
    const previewed = ops(page!.provider, "cmux.settings.preview").at(-1) as { key: string; value: string };
    expect(previewed.key).toBe(KEY);
    expect(typeof previewed.value).toBe("string");
    await fire(search, "keydown", { key: "Enter" });
    expect(ops(page!.provider, "cmux.settings.set").at(-1)).toEqual({ key: KEY, value: previewed.value });
  });

  test("the row's sample draws interface text in the picked family", async () => {
    page = await renderPage({ path: "/settings/appearance", mock: { values: { [KEY]: "Avenir Next" } } });
    const sample = rowElement(page.container, KEY).querySelector<HTMLElement>(".font-sample")!;
    expect(sample.dataset.specimen).toBe("text");
    expect(sample.textContent).toBe(UI_SPECIMEN);
    expect(sample.querySelector<HTMLElement>("span")!.style.fontFamily).toContain("Avenir Next");
  });
});
