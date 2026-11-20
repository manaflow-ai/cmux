// Settings > Personalization (Leo, 2026-11-07: the profile menu's "fast jump into the settings of the
// appearance section"): one page with every visual choice, drawn by the same cards and rows as their
// home categories. These tests hold it to one source of truth: every key it draws is a row of another
// category, every row it draws is the same row (same key) on that category's page, and a pick on it
// is the same write a pick on Settings > Chief makes.
import { act } from "react";
import { afterAll, expect, test } from "bun:test";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle, ops } = await import("./testing");
const { homes, categoryById } = await import("./categories");
const { PERSONALIZATION_KEYS, PERSONALIZATION_PARTS } = await import("./components/PersonalizationCard");
const { DENSITY_CARD_ROWS } = await import("./density");
const { ROW_LEVELS } = await import("./rowLevelsData");
/** The keys only Personalization draws (SectionView HUB_KEYS): its parts' and its density card's. */
const HUB_KEYS = new Set([...PERSONALIZATION_KEYS, ...DENSITY_CARD_ROWS]);

const rowKeys = (container: HTMLElement) =>
  [...container.querySelectorAll<HTMLElement>(".row[data-row-key]")].map((row) => row.dataset.rowKey!);

// The Theme page moved here (page-layout.json: legacy_ids ["theme"]), so the theme keys' home is this
// page, by its App Theme group; every other key it draws has its home in another category.
const THEME_KEYS = new Set(["appearance.theme", "appearance.appTheme", "appearance.accent"]);

test("every key Personalization draws has its one home: the theme here, the rest in another category", () => {
  expect(categoryById("personalization").groups.map((group) => group.key)).toEqual(["settings.group.appTheme"]);
  for (const key of PERSONALIZATION_KEYS) {
    const home = homes.get(key);
    expect(home, key).toBeDefined();
    if (THEME_KEYS.has(key)) expect(home!.category, key).toBe("personalization");
    else expect(home!.category, key).not.toBe("personalization");
  }
});

test("the page draws each part under its jump bar: theme, background, Chief, text and sounds", async () => {
  const page = await renderPage({ path: "/settings/personalization" });
  await settle();
  const card = page.container.querySelector<HTMLElement>('[data-card="personalization"]')!;
  expect(card).not.toBeNull();
  const jumps = [...card.querySelectorAll<HTMLElement>("[data-jump]")].map((link) => link.dataset.jump);
  expect(jumps).toEqual(["theme", "background", "chief", "text", "sounds"]);
  const parts = [...card.querySelectorAll<HTMLElement>("[data-part]")].map((part) => part.dataset.part);
  expect(parts).toEqual(jumps);
  const part = (id: string) => card.querySelector<HTMLElement>(`[data-part="${id}"]`)!;
  // The theme studio with its live preview, the Chief's look and the density tiles: the home cards.
  expect(part("theme").querySelector(".theme-preview, [data-theme-preview], svg")).not.toBeNull();
  expect(part("chief").querySelector('[data-card="chief-pet"]')).not.toBeNull();
  // Agents' whole Chat Text card, then the transcript view.
  for (const key of [
    "agentPane.display.font.ui",
    "agentPane.display.font.preset",
    "agentPane.display.font.size",
    "agentPane.display.font.lineHeight",
    "agentPane.display.code.family",
    "agentPane.display.code.scale",
    "agentPane.display.transcriptView",
  ])
    expect(rowKeys(part("text"))).toContain(key);
  expect(part("text").querySelector('[data-more="appearance"]')).not.toBeNull();
  expect(rowKeys(part("sounds"))).toEqual([
    "notifications.sound",
    "notifications.sounds.volume",
    "notifications.sounds.when",
  ]);
  // The Undo bar of Appearance and Theme shows here too.
  expect(page.container.querySelector("[data-appearance-bar]")).not.toBeNull();
  page.unmount();
});

// Personalization is the one page that draws its own keys (SectionView HUB_KEYS): their home pages
// no longer draw them a second time. A row it repeats from a card of another page (the Chief's chat
// rows in Look) is still that same row on its home page, unless that page hides it.
test("every row it draws is drawn once: its own keys on no other page, the rest on their home, and More in … opens that page", async () => {
  const page = await renderPage({ path: "/settings/personalization" });
  await settle();
  const drawn = rowKeys(page.container);
  expect(drawn.length).toBeGreaterThan(5);
  const byHome = new Map<string, string[]>();
  for (const key of drawn) {
    const home = homes.get(key)!.category;
    if (home === "personalization") continue;
    byHome.set(home, [...(byHome.get(home) ?? []), key]);
  }
  for (const [home, keys] of byHome) {
    await act(async () => page.history.push(`/settings/${home}`));
    await settle();
    const there = new Set(rowKeys(page.container));
    // A row hidden on its home page (rowLevelsData.ts) shows only here and in search.
    for (const key of keys)
      expect(there.has(key), `${key} on ${home}`).toBe(!HUB_KEYS.has(key) && ROW_LEVELS.levels[key] !== "hidden");
  }
  // Each part's More in … links go to the homes of what it draws, and every home has its link.
  for (const part of PERSONALIZATION_PARTS) {
    await act(async () => page.history.push("/settings/personalization"));
    await settle();
    const section = page.container.querySelector<HTMLElement>(`[data-part="${part.id}"]`)!;
    const drawnHomes = new Set(rowKeys(section).map((key) => homes.get(key)!.category));
    // The theme's home is this page, so its part links nowhere.
    drawnHomes.delete("personalization");
    for (const home of drawnHomes) expect(part.homes, `${part.id} links ${home}`).toContain(home);
    for (const home of part.homes) {
      await act(async () => page.history.push("/settings/personalization"));
      await settle();
      const more = page.container.querySelector<HTMLElement>(`[data-part="${part.id}"] [data-more="${home}"]`)!;
      await act(async () => more.click());
      await settle();
      expect(page.history.location.pathname).toBe(`/settings/${home}`);
    }
  }
  page.unmount();
});

test("a pick on Personalization is the write Settings makes, and Settings shows it", async () => {
  const page = await renderPage({ path: "/settings/personalization" });
  await settle();
  const pet = () => page.container.querySelector<HTMLElement>('[data-card="chief-pet"]')!;
  await act(async () => pet().querySelector<HTMLElement>('[data-pet="fox"]')!.click());
  await settle();
  expect(ops(page.provider, "cmux.settings.set")).toEqual([{ key: "home.chiefPetMascot", value: "fox" }]);
  // Chief no longer draws the pet card (Personalization is its one home): coming back shows the pick.
  await act(async () => page.history.push("/settings/chief"));
  await settle();
  expect(pet()).toBeNull();
  await act(async () => page.history.push("/settings/personalization"));
  await settle();
  const checked = [...pet().querySelectorAll<HTMLElement>(".chief-pet-choice")].find(
    (choice) => choice.getAttribute("aria-pressed") === "true",
  );
  expect(checked?.dataset.pet).toBe("fox");
  page.unmount();
});

test("Change Background… opens it on its Background part", async () => {
  const page = await renderPage({ path: "/settings/personalization?focus=personalization.background&workspace=ws-1" });
  await settle();
  const current = page.container.querySelector<HTMLElement>('[data-jump][aria-current="true"]');
  expect(current?.dataset.jump).toBe("background");
  expect(page.container.querySelector('[data-section="personalization"]')).not.toBeNull();
  page.unmount();
});

test("a jump marks its part current, and a second Change Background… lands on Background again", async () => {
  // The host's real sequence: Change Background… opens a route with its own `open`, the person jumps
  // to Sounds, then Change Background… again opens a new route (another `open`) on Background.
  const page = await renderPage({ path: "/settings/personalization?focus=personalization.background&open=1" });
  await settle();
  const current = () => page.container.querySelector<HTMLElement>('[data-jump][aria-current="true"]')?.dataset.jump;
  const scrolled: string[] = [];
  const original = HTMLElement.prototype.scrollIntoView;
  HTMLElement.prototype.scrollIntoView = function (this: HTMLElement) {
    if (this.dataset.part) scrolled.push(this.dataset.part);
  };
  expect(current()).toBe("background");
  await act(async () => page.container.querySelector<HTMLElement>('[data-jump="sounds"]')!.click());
  await settle();
  expect(current()).toBe("sounds");
  expect(page.history.location.search).toContain("focus=personalization.sounds");
  expect(scrolled).toEqual(["sounds"]);
  await act(async () => page.history.push("/settings/personalization?focus=personalization.background&open=2"));
  await settle();
  expect(current()).toBe("background");
  expect(scrolled).toEqual(["sounds", "background"]);
  // A repeat on the part already shown (the person scrolled away) scrolls back to it.
  await act(async () => page.history.push("/settings/personalization?focus=personalization.background&open=3"));
  await settle();
  expect(scrolled).toEqual(["sounds", "background", "background"]);
  HTMLElement.prototype.scrollIntoView = original;
  page.unmount();
});

test("Change Background… waits for the host's lists before it reveals Background", async () => {
  // The host's lists add the Theme part's override lines and Background's art picker above and in
  // the part: a reveal on the values alone landed short once they grew (gallery backdrops-workspace).
  let release = () => {};
  const scrolled: string[] = [];
  const original = HTMLElement.prototype.scrollIntoView;
  HTMLElement.prototype.scrollIntoView = function (this: HTMLElement) {
    if (this.dataset.part) scrolled.push(this.dataset.part);
  };
  const page = await renderPage({
    path: "/settings/personalization?focus=personalization.background&open=1",
    drawBeforeStart: true,
    setup: (provider) => void (provider.holdHost = new Promise<void>((resolve) => (release = resolve))),
  });
  await settle();
  expect(page.store.getSnapshot().host).toBeNull();
  expect(scrolled).toEqual([]);
  await act(async () => release());
  await settle();
  expect(scrolled).toEqual(["background"]);
  HTMLElement.prototype.scrollIntoView = original;
  page.unmount();
});

test("a jump to Theme, the first part, scrolls the page to its very top so its title shows", async () => {
  const page = await renderPage({ path: "/settings/personalization?focus=personalization.sounds" });
  await settle();
  const content = page.container.querySelector<HTMLElement>(".content")!;
  const tops: number[] = [];
  content.scrollTo = ((options: ScrollToOptions) => void tops.push(options.top ?? -1)) as typeof content.scrollTo;
  const scrolled: string[] = [];
  const original = HTMLElement.prototype.scrollIntoView;
  HTMLElement.prototype.scrollIntoView = function (this: HTMLElement) {
    if (this.dataset.part) scrolled.push(this.dataset.part);
  };
  await act(async () => page.container.querySelector<HTMLElement>('[data-jump="theme"]')!.click());
  await settle();
  expect(tops).toEqual([0]);
  expect(scrolled).toEqual([]);
  HTMLElement.prototype.scrollIntoView = original;
  page.unmount();
});

test("without art to pick, Background still draws the shuffle interval Appearance shows", async () => {
  const page = await renderPage({
    path: "/settings/personalization",
    setup: (provider) => void (provider.host = { ...provider.host, backdrops: [] }),
  });
  await settle();
  expect(rowKeys(page.container.querySelector<HTMLElement>('[data-part="background"]')!)).toContain(
    "appearance.backgroundRotation",
  );
  page.unmount();
});
