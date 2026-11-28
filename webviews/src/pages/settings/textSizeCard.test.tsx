// Settings opens on General, and General's first card is Text Size (David Beyer, Nov 20: "Settings is
// overwhelming", he could not find a sidebar font size). One choice writes appearance.metrics.chromeFontSize,
// which sizes the sidebar, tabs, menus and chat together; the density choice beside it writes appearance.density.
import { afterAll, afterEach, expect, test } from "bun:test";
import { installDom } from "./testDom";
import type { Rendered } from "./testing";
import { DENSITY_KEY, TEXT_SIZE_KEY } from "./density";

const restore = installDom();
afterAll(() => restore());
const { click, renderPage } = await import("./testing");
let page: Rendered | null = null;
afterEach(() => {
  page?.unmount();
  page = null;
});

const value = (key: string) => page!.store.getSnapshot().rows.get(key)?.value ?? null;
const size = (id: string) => page!.container.querySelector<HTMLInputElement>(`input[data-text-size="${id}"]`)!;
const density = (id: string) => page!.container.querySelector<HTMLInputElement>(`input[data-density-choice="${id}"]`)!;

test("General opens on the Text Size card, ahead of every other card", async () => {
  page = await renderPage({ path: "/settings/general", mock: { values: { [DENSITY_KEY]: "cozy" } } });
  const section = page.container.querySelector<HTMLElement>(".section[data-section='general']")!;
  const cards = [...section.querySelectorAll<HTMLElement>("[data-card]")].map((card) => card.dataset.card);
  expect(cards[0]).toBe("textSize");
  // Unset is Default, and Default is checked.
  expect(size("default").checked).toBe(true);
  expect(density("cozy").checked).toBe(true);
});

test("a size writes the chrome text size in points over the density's own, and Default removes it", async () => {
  page = await renderPage({ path: "/settings/general", mock: { values: { [DENSITY_KEY]: "cozy" } } });
  // Default density draws 14 pt chrome text: Larger is two points over it, Largest four.
  await click(size("larger"));
  expect(value(TEXT_SIZE_KEY)).toBe(16);
  expect(size("larger").checked).toBe(true);
  await click(size("largest"));
  expect(value(TEXT_SIZE_KEY)).toBe(18);
  await click(size("default"));
  expect(value(TEXT_SIZE_KEY)).toBeNull();
});

test("the density choice writes appearance.density, and sizes follow the new density's text", async () => {
  page = await renderPage({ path: "/settings/general", mock: { values: { [DENSITY_KEY]: "cozy" } } });
  await click(density("compact"));
  expect(value(DENSITY_KEY)).toBe("compact");
  // Compact draws 12.6 pt: Large is a whole point over it, rounded.
  await click(size("large"));
  expect(value(TEXT_SIZE_KEY)).toBe(14);
});
