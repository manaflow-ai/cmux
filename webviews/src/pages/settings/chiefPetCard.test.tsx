// Chief Pet (after ChatGPT's Mini & Pets): the category's card previews the pet over its rail,
// shows or hides it with Show Pet / Hide Pet, and picks the Chief's character from a grid of the
// Chief Dock's mascots. The character is the Chief's avatar on every surface, so the chosen one is
// checked whether or not the pet is shown, and picking one never shows the pet. The card draws the
// category's two rows, so they are not listed again below it.
import { act } from "react";
import { afterAll, expect, test } from "bun:test";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle, ops } = await import("./testing");

const card = (container: HTMLElement) => container.querySelector<HTMLElement>('[data-card="chief-pet"]')!;
const choices = (element: HTMLElement) => [...element.querySelectorAll<HTMLElement>(".chief-pet-choice")];
/** The pet as the card shows it: on or off, and the character in its preview. */
const shown = (element: HTMLElement) => ({
  enabled: element.dataset.enabled === "true",
  character: element.querySelector<HTMLImageElement>(".chief-pet-art")?.alt,
});
const checked = (element: HTMLElement) =>
  choices(element).find((choice) => choice.getAttribute("aria-pressed") === "true")?.dataset.pet;

test("the page shows every character, the chosen one checked while the pet is off", async () => {
  const page = await renderPage({ path: "/settings/chief" });
  await settle();
  const pet = card(page.container);
  expect(choices(pet).map((choice) => choice.dataset.pet)).toEqual([
    "fox",
    "machine",
    "machine-cyan",
    "machine-blue",
    "moon",
    "moon-blue",
    "mochi",
    "captain",
    "sprout",
    "bolt",
    "fox-arctic",
    "machine-violet",
    "machine-gold",
    "moon-rose",
    "orb",
    "orb-spark",
    "orb-hood",
  ]);
  // The pet is off by default, but every Chief surface wears the default character, orb, wherever it
  // sits in the grid (Series 1 without the orbs, the animated sets, Series 2, then the orbs): it is the one checked.
  expect(checked(pet)).toBe("orb");
  expect(pet.dataset.enabled).toBe("false");
  // The card draws both rows: no plain toggle or menu for them below it.
  expect(page.container.querySelector('.row[data-row-key="home.chiefPetEnabled"]')).toBeNull();
  expect(page.container.querySelector('.row[data-row-key="home.chiefPetMascot"]')).toBeNull();
  page.unmount();
});

test("picking a character with the pet off swaps the avatar and leaves the pet off", async () => {
  const page = await renderPage({ path: "/settings/chief" });
  await settle();
  const pick = async (id: string) => {
    await act(async () => card(page.container).querySelector<HTMLElement>(`[data-pet="${id}"]`)!.click());
    await settle();
  };
  await pick("fox");
  expect(shown(card(page.container))).toEqual({ enabled: false, character: "Fox" });
  expect(checked(card(page.container))).toBe("fox");
  expect(ops(page.provider, "cmux.settings.set")).toEqual([{ key: "home.chiefPetMascot", value: "fox" }]);
  await pick("moon");
  expect(shown(card(page.container))).toEqual({ enabled: false, character: "Moon" });
  expect(checked(card(page.container))).toBe("moon");
  expect(
    ops(page.provider, "cmux.settings.set").some(
      (params) => (params as { key: string }).key === "home.chiefPetEnabled",
    ),
  ).toBe(false);
  page.unmount();
});

test("picking a character with the pet shown swaps it and keeps it shown", async () => {
  const page = await renderPage({ path: "/settings/chief", mock: { values: { "home.chiefPetEnabled": true } } });
  await settle();
  await act(async () => card(page.container).querySelector<HTMLElement>('[data-pet="fox"]')!.click());
  await settle();
  expect(shown(card(page.container))).toEqual({ enabled: true, character: "Fox" });
  expect(checked(card(page.container))).toBe("fox");
  page.unmount();
});

test("Show Pet and Hide Pet turn the pet on and off with its character kept", async () => {
  const page = await renderPage({ path: "/settings/chief", mock: { values: { "home.chiefPetMascot": "moon" } } });
  await settle();
  const toggle = () => card(page.container).querySelector<HTMLButtonElement>('[data-action="chief-pet-toggle"]')!;
  expect(toggle().textContent).toBe("Show Pet");
  await act(async () => toggle().click());
  await settle();
  expect(shown(card(page.container))).toEqual({ enabled: true, character: "Moon" });
  expect(checked(card(page.container))).toBe("moon");
  expect(toggle().textContent).toBe("Hide Pet");
  await act(async () => toggle().click());
  await settle();
  expect(shown(card(page.container))).toEqual({ enabled: false, character: "Moon" });
  page.unmount();
});

test("hovering a character previews it without picking it", async () => {
  const page = await renderPage({ path: "/settings/chief", mock: { values: { "home.chiefPetMascot": "moon" } } });
  await settle();
  const fox = card(page.container).querySelector<HTMLElement>('[data-pet="fox"]')!;
  const preview = () => card(page.container).querySelector<HTMLElement>(".chief-pet-preview")!;
  // React's onMouseEnter and onMouseLeave come from mouseover and mouseout.
  await act(async () => fox.dispatchEvent(new window.MouseEvent("mouseover", { bubbles: true })));
  expect(shown(card(page.container)).character).toBe("Fox");
  expect(preview().dataset.previewing).toBe("true");
  expect(checked(card(page.container))).toBe("moon");
  await act(async () => fox.dispatchEvent(new window.MouseEvent("mouseout", { bubbles: true })));
  expect(shown(card(page.container))).toEqual({ enabled: false, character: "Moon" });
  expect(preview().dataset.previewing).toBe("false");
  page.unmount();
});

// Leo 2026-11-01: "obv i assume this won't switch up what they've currently selected...?" The value is
// the character's id, so a saved choice stays checked after the reorder, and an id that is no character
// checks the default, orb, not the grid's first cell.
test("a saved character stays checked after the reorder; an unknown one checks orb", async () => {
  const saved = await renderPage({ path: "/settings/chief", mock: { values: { "home.chiefPetMascot": "moon" } } });
  await settle();
  expect(checked(card(saved.container))).toBe("moon");
  saved.unmount();
  const unknown = await renderPage({
    path: "/settings/chief",
    mock: { values: { "home.chiefPetMascot": "retired-character" } },
  });
  await settle();
  expect(checked(card(unknown.container))).toBe("orb");
  unknown.unmount();
});
