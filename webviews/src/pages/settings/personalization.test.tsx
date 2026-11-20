// Personalization draws its home settings through the same cards and store as the rest of Settings.
import { act } from "react";
import { afterAll, expect, test } from "bun:test";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { click, renderPage, run, settle, ops } = await import("./testing");
const { homes, categoryById } = await import("./categories");
const { PERSONALIZATION_KEYS, PERSONALIZATION_PARTS } = await import("./personalizationParts");
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

test("Personalization expands its sidebar rows and shows one panel at a time", async () => {
  const page = await renderPage({ path: "/settings/general" });
  const parent = page.container.querySelector<HTMLElement>('[data-section-link="personalization"]')!;
  const group = page.container.querySelector("#personalization-links")!;
  const part = (id: string) => page.container.querySelector<HTMLElement>(`[data-part-link="${id}"]`)!;
  const panel = () => page.container.querySelector<HTMLElement>("[data-card=personalization] [data-part]")!;
  const active = () => group.querySelector('[aria-current="page"]')?.getAttribute("data-part-link");
  const checkHeading = (id: string) => {
    const headings = page.container.querySelectorAll(".content h1");
    expect(headings).toHaveLength(1);
    expect(headings[0]?.textContent).toBe(part(id).textContent);
  };

  expect(parent.getAttribute("aria-expanded")).toBe("false");
  expect(group.hasAttribute("inert")).toBe(true);
  await click(parent);
  expect(parent.getAttribute("aria-expanded")).toBe("true");
  expect(group.hasAttribute("inert")).toBe(false);
  expect(active()).toBe("theme");
  checkHeading("theme");
  const currentLinks = page.container.querySelectorAll('.section-list [aria-current="page"]');
  expect(currentLinks).toHaveLength(1);
  expect(currentLinks[0]).toBe(part("theme"));
  expect(panel().querySelector("[data-theme-picker]")).not.toBeNull();
  expect(page.container.querySelector("[data-jump-bar]")).toBeNull();

  await click(part("background"));
  checkHeading("background");

  await click(part("chief"));
  expect(active()).toBe("chief");
  checkHeading("chief");
  expect(panel().querySelector('[data-card="chief-pet"]')).not.toBeNull();
  expect(page.container.querySelector("[data-theme-picker]")).toBeNull();

  await click(part("text"));
  expect(active()).toBe("text");
  checkHeading("text");
  expect(panel().querySelector('[data-card="density"]')).not.toBeNull();
  expect(rowKeys(panel())).toContain("agentPane.display.font.ui");

  await click(part("sounds"));
  expect(active()).toBe("sounds");
  checkHeading("sounds");
  expect(rowKeys(panel())).toEqual(["notifications.sound", "notifications.sounds.volume", "notifications.sounds.when"]);
  expect(page.container.querySelector("[data-appearance-bar]")).not.toBeNull();

  await run(() => page.history.back());
  expect(active()).toBe("text");
  await run(() => page.history.forward());
  expect(active()).toBe("sounds");

  await click(page.container.querySelector('[data-section-link="appearance"]')!);
  expect(parent.getAttribute("aria-expanded")).toBe("false");
  expect(group.hasAttribute("inert")).toBe(true);
  expect(active()).toBeUndefined();
  page.unmount();
});

// Personalization is the one page that draws its own keys (SectionView HUB_KEYS): their home pages
// no longer draw them a second time. A row it repeats from a card of another page (the Chief's chat
// rows in Look) is still that same row on its home page, unless that page hides it.
test("every row it draws is drawn once: its own keys on no other page, the rest on their home, and More in … opens that page", async () => {
  const page = await renderPage({ path: "/settings/personalization" });
  await settle();
  const drawn: string[] = [];
  for (const { id } of PERSONALIZATION_PARTS) {
    await run(() => page.history.push(`/settings/personalization?part=${id}`));
    drawn.push(...rowKeys(page.container));
  }
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
    await run(() => page.history.push(`/settings/personalization?part=${part.id}`));
    const section = page.container.querySelector<HTMLElement>(`[data-part="${part.id}"]`)!;
    const drawnHomes = new Set(rowKeys(section).map((key) => homes.get(key)!.category));
    // The theme's home is this page, so its part links nowhere.
    drawnHomes.delete("personalization");
    for (const home of drawnHomes) expect(part.homes, `${part.id} links ${home}`).toContain(home);
    for (const home of part.homes) {
      await run(() => page.history.push(`/settings/personalization?part=${part.id}`));
      const more = page.container.querySelector<HTMLElement>(`[data-part="${part.id}"] [data-more="${home}"]`)!;
      await act(async () => more.click());
      await settle();
      expect(page.history.location.pathname).toBe(`/settings/${home}`);
    }
  }
  page.unmount();
});

test("a pick on Personalization is the write Settings makes, and Settings shows it", async () => {
  const page = await renderPage({ path: "/settings/personalization?part=chief" });
  await settle();
  const pet = () => page.container.querySelector<HTMLElement>('[data-card="chief-pet"]')!;
  await act(async () => pet().querySelector<HTMLElement>('[data-pet="fox"]')!.click());
  await settle();
  expect(ops(page.provider, "cmux.settings.set")).toEqual([{ key: "home.chiefPetMascot", value: "fox" }]);
  // Chief no longer draws the pet card (Personalization is its one home): coming back shows the pick.
  await act(async () => page.history.push("/settings/chief"));
  await settle();
  expect(pet()).toBeNull();
  await act(async () => page.history.push("/settings/personalization?part=chief"));
  await settle();
  const checked = [...pet().querySelectorAll<HTMLElement>(".chief-pet-choice")].find(
    (choice) => choice.getAttribute("aria-pressed") === "true",
  );
  expect(checked?.dataset.pet).toBe("fox");
  page.unmount();
});

test("Change Background… selects Background, keeps its workspace, and can reopen it", async () => {
  const path = "/settings/personalization?focus=personalization.background&workspace=ws-1";
  const page = await renderPage({
    path: `${path}&open=1`,
    mock: {
      values: { "appearance.background": "starryNight" },
      workspaceBackgrounds: [{ workspace: "ws-1", title: "Research", value: null }],
    },
  });
  const current = () =>
    page.container.querySelector('[data-part-link][aria-current="page"]')?.getAttribute("data-part-link");
  const savedTile = () => page.container.querySelector('.backdrop-tile[aria-label="The Starry Night"]');
  expect(current()).toBe("background");
  expect(document.activeElement).toBe(savedTile());

  await click(page.container.querySelector('[data-part-link="sounds"]')!);
  expect(current()).toBe("sounds");
  expect(page.history.location.search).toContain("workspace=ws-1");
  await run(() => page.history.push(`${path}&open=2`));
  expect(current()).toBe("background");
  expect(document.activeElement).toBe(savedTile());

  const search = page.container.querySelector<HTMLInputElement>("[data-settings-search]")!;
  search.focus();
  expect(document.activeElement).toBe(search);
  await run(() => page.history.push(`${path}&open=3`));
  expect(document.activeElement).toBe(savedTile());
  page.unmount();
});

test("selecting a sidebar panel opens it at the top without focusing a control", async () => {
  const page = await renderPage({ path: "/settings/personalization?part=text" });
  const content = page.container.querySelector<HTMLElement>(".content")!;
  const tops: number[] = [];
  content.scrollTo = ((options: ScrollToOptions) => void tops.push(options.top ?? -1)) as typeof content.scrollTo;
  const background = page.container.querySelector<HTMLElement>('[data-part-link="background"]')!;
  background.focus();
  await click(background);
  expect(tops.length).toBeGreaterThan(0);
  expect(tops.every((top) => top === 0)).toBe(true);
  expect(document.activeElement).toBe(background);
  page.unmount();
});

test("reopening Theme from a legacy part link resets its scroll position", async () => {
  const page = await renderPage({ path: "/settings/personalization" });
  const content = page.container.querySelector<HTMLElement>(".content")!;
  const tops: number[] = [];
  content.scrollTo = ((options: ScrollToOptions) => void tops.push(options.top ?? -1)) as typeof content.scrollTo;
  await run(() => page.history.push("/settings/personalization?focus=personalization.theme&open=1"));
  await run(() => page.history.push("/settings/personalization?focus=personalization.theme&open=2"));
  expect(tops).toEqual([0, 0]);
  page.unmount();
});

test("without art to pick, Background still draws the shuffle interval Appearance shows", async () => {
  const page = await renderPage({
    path: "/settings/personalization?part=background",
    setup: (provider) => void (provider.host = { ...provider.host, backdrops: [] }),
  });
  await settle();
  expect(rowKeys(page.container.querySelector<HTMLElement>('[data-part="background"]')!)).toContain(
    "appearance.backgroundRotation",
  );
  page.unmount();
});
