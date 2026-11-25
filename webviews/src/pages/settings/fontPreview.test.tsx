// Font rows' pictures (FontPreview). Leo, 2026-11-19: "idk i dont have pictures to see or sliders to
// adjust for the font". Every face choice draws a tile in its own face at the surface's size and line
// height, a click on a tile picks it, a size slider's drag resizes the tiles before the release writes,
// and a font family row draws a sample of the picked family at its size.
import { afterAll, afterEach, describe, expect, test } from "bun:test";
import { FONT_PREVIEWS, familyStack } from "./fontPreviewModel";
import { installDom } from "./testDom";
import type { Rendered } from "./testing";

const restore = installDom();
afterAll(() => restore());
const { changeValue, click, fire, ops, renderPage, rowElement, run } = await import("./testing");

let page: Rendered | null = null;
afterEach(() => {
  page?.unmount();
  page = null;
});

const UI = "agentPane.display.font.ui";
const SIZE = "agentPane.display.font.size";
const tiles = (key: string) => [...rowElement(page!.container, key).querySelectorAll<HTMLElement>(".font-tile")];
const picture = (tile: HTMLElement) => tile.querySelector<HTMLElement>(".font-tile-picture")!;
const slider = (key: string) =>
  rowElement(page!.container, key).querySelector<HTMLInputElement>('input[type="range"]')!;

describe("font pictures", () => {
  test("the Interface Font row draws a tile per choice, each in its own face, the current one marked", async () => {
    page = await renderPage({ path: "/settings/chat" });
    const all = tiles(UI);
    expect(all.map((tile) => tile.dataset.fontChoice)).toContain("cmux-sans");
    expect(all.length).toBeGreaterThanOrEqual(10);
    const cmux = all.find((tile) => tile.dataset.fontChoice === "cmux-sans")!;
    expect(picture(cmux).style.fontFamily).toContain("cmux Sans");
    const on = all.filter((tile) => tile.getAttribute("aria-checked") === "true");
    expect(on.map((tile) => tile.dataset.fontChoice)).toEqual(["system-ui"]);
  });

  test("a click on a tile writes that choice", async () => {
    page = await renderPage({ path: "/settings/chat" });
    const geist = tiles(UI).find((tile) => tile.dataset.fontChoice === "geist")!;
    await click(geist);
    expect(ops(page.provider, "cmux.settings.set").at(-1)).toEqual({ key: UI, value: "geist" });
  });

  test("the size slider resizes every tile while it drags, and its release keeps the size", async () => {
    page = await renderPage({ path: "/settings/chat" });
    expect(picture(tiles(UI)[0]!).style.fontSize).toBe("14px");
    await changeValue(slider(SIZE), "20");
    for (const tile of tiles(UI)) expect(picture(tile).style.fontSize).toBe("20px");
    await fire(slider(SIZE), "change");
    await run(() => undefined);
    expect(picture(tiles(UI)[0]!).style.fontSize).toBe("20px");
  });

  test("the Chat Font's Markdown choice draws the Markdown viewer's preset", async () => {
    page = await renderPage({ path: "/settings/chat" });
    const preset = "agentPane.display.font.preset";
    const markdown = () => tiles(preset).find((tile) => tile.dataset.fontChoice === "markdown")!;
    expect(picture(markdown()).style.fontFamily).toContain("system-ui");
    await run(() => page!.store.set("markdown.font.preset", "serif"));
    expect(picture(markdown()).style.fontFamily).toContain("Georgia");
  });

  test("the Chat Font choices that follow the interface face draw in the Interface Font", async () => {
    page = await renderPage({ path: "/settings/chat" });
    const preset = "agentPane.display.font.preset";
    const tile = (choice: string) => picture(tiles(preset).find((t) => t.dataset.fontChoice === choice)!);
    // On the default Interface Font both System and a system-preset Markdown draw the system face.
    expect(tile("system").style.fontFamily).toContain("system-ui");
    await run(() => page!.store.set("agentPane.display.font.ui", "cmux-sans"));
    // The chat draws these in `var(--font-ui)`, which the Interface Font sets: so does the picture.
    expect(tile("system").style.fontFamily).toContain("cmux Sans");
    expect(tile("markdown").style.fontFamily).toContain("cmux Sans");
    // The faces that do not follow it are unmoved.
    expect(tile("serif").style.fontFamily).toContain("Georgia");
    expect(tile("mono").style.fontFamily).not.toContain("cmux Sans");
  });

  test("the mono tiles draw in the configured code family, the chat's before the viewer's before the terminal's", async () => {
    page = await renderPage({ path: "/settings/chat" });
    const preset = "agentPane.display.font.preset";
    const mono = () => picture(tiles(preset).find((t) => t.dataset.fontChoice === "mono")!);
    expect(mono().style.fontFamily).toContain("ui-monospace");
    await run(() => page!.store.set("terminal.fontFamily", "Menlo"));
    // Code follows the terminal font unless a code font is set (chatDisplay.ts).
    expect(mono().style.fontFamily).toContain("Menlo");
    await run(() => page!.store.set("markdown.code.family", "Iosevka"));
    expect(mono().style.fontFamily).toContain("Iosevka");
    await run(() => page!.store.set("agentPane.display.code.family", "Berkeley Mono"));
    expect(mono().style.fontFamily).toContain("Berkeley Mono");
  });

  test("the terminal's font row draws a sample of the picked family at its size", async () => {
    page = await renderPage({ path: "/settings/terminal" });
    const sample = () => rowElement(page!.container, "terminal.fontFamily").querySelector<HTMLElement>(".font-sample")!;
    expect(sample().dataset.fontSample).toBe("");
    await run(() => page!.store.set("terminal.fontFamily", "Menlo"));
    await run(() => page!.store.set("terminal.fontSize", 17));
    expect(sample().dataset.fontSample).toBe("Menlo");
    expect(sample().dataset.size).toBe("17");
    expect(sample().querySelector("span")!.style.fontFamily).toContain("Menlo");
  });

  test("a page that does not hold the row is refused, alias or not", async () => {
    const { sectionShowing } = await import("./categories");
    // Where the chat's font rows actually live, after Personalization folded into Appearance.
    expect(sectionShowing("chat", UI)).toBe("chat");
    // `personalization` still opens a page (Appearance's alias), just not this row's: the old name
    // used to capture the wrong page and wait for a row that never drew.
    expect(() => sectionShowing("personalization", UI)).toThrow(/opens "appearance".*is on "chat"/);
    expect(() => sectionShowing("chat", "terminal.fontFamily")).toThrow(/is on "terminal"/);
    expect(() => sectionShowing("chat", "no.such.row")).toThrow(/no row/);
  });

  test("every previewed row exists in the schema, and a family name cannot break out of its stack", async () => {
    const { rowsByKey } = await import("./schema");
    for (const [key, preview] of Object.entries(FONT_PREVIEWS)) {
      expect(rowsByKey.get(key)).toBeDefined();
      expect(rowsByKey.get(preview.size)?.kind).toBe("number");
    }
    expect(familyStack('Evil", serif; x')).toBe('"Evil, serif; x", monospace');
  });
});
