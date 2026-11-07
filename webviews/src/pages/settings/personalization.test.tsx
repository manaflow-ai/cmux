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

const rowKeys = (container: HTMLElement) =>
  [...container.querySelectorAll<HTMLElement>(".row[data-row-key]")].map((row) => row.dataset.rowKey!);

test("every key Personalization draws has its one home in another category", () => {
  expect(categoryById("personalization").groups).toEqual([]);
  for (const key of PERSONALIZATION_KEYS) {
    const home = homes.get(key);
    expect(home, key).toBeDefined();
    expect(home!.category, key).not.toBe("personalization");
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

test("every row it draws is the same row on its home page, and More in … opens that page", async () => {
  const page = await renderPage({ path: "/settings/personalization" });
  await settle();
  const drawn = rowKeys(page.container);
  expect(drawn.length).toBeGreaterThan(5);
  const byHome = new Map<string, string[]>();
  for (const key of drawn) {
    const home = homes.get(key)!.category;
    byHome.set(home, [...(byHome.get(home) ?? []), key]);
  }
  for (const [home, keys] of byHome) {
    await act(async () => page.history.push(`/settings/${home}`));
    await settle();
    const there = new Set(rowKeys(page.container));
    for (const key of keys) expect(there.has(key), `${key} on ${home}`).toBe(true);
  }
  // Each part's More in … links go to the homes of what it draws, and every home has its link.
  for (const part of PERSONALIZATION_PARTS) {
    await act(async () => page.history.push("/settings/personalization"));
    await settle();
    const section = page.container.querySelector<HTMLElement>(`[data-part="${part.id}"]`)!;
    const drawnHomes = new Set(rowKeys(section).map((key) => homes.get(key)!.category));
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
  await act(async () => page.history.push("/settings/chief"));
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
