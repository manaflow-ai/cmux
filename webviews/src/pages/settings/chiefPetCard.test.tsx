// Chief Pet (after ChatGPT's Mini & Pets): the category's card previews the pet over its rail,
// shows or hides it, and picks its character from a grid of the Chief Dock's mascots, with None
// to hide it. It draws the category's two rows, so they are not listed again below it.
import { act } from "react";
import { afterAll, expect, test } from "bun:test";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle } = await import("./testing");

const card = (container: HTMLElement) => container.querySelector<HTMLElement>('[data-card="chief-pet"]')!;
const choices = (element: HTMLElement) => [...element.querySelectorAll<HTMLElement>(".chief-pet-choice")];
/** The pet as the card shows it: on or off, and the character in its preview. */
const shown = (element: HTMLElement) => ({
  enabled: element.dataset.enabled === "true",
  character: element.querySelector<HTMLImageElement>(".chief-pet-art")?.alt,
});
const checked = (element: HTMLElement) =>
  choices(element).find((choice) => choice.getAttribute("aria-pressed") === "true")?.dataset.pet;

test("the page shows None and every character, None chosen while the pet is off", async () => {
  const page = await renderPage({ path: "/settings/chief-pet" });
  await settle();
  const pet = card(page.container);
  expect(choices(pet).map((choice) => choice.dataset.pet)).toEqual([
    "none",
    "orb",
    "orb-spark",
    "orb-hood",
    "machine",
    "machine-cyan",
    "machine-blue",
    "moon",
    "moon-blue",
    "fox",
  ]);
  expect(checked(pet)).toBe("none");
  expect(pet.dataset.enabled).toBe("false");
  // The card draws both rows: no plain toggle or menu for them below it.
  expect(page.container.querySelector('[data-key="home.chiefPetEnabled"]')).toBeNull();
  expect(page.container.querySelector('[data-key="home.chiefPetMascot"]')).toBeNull();
  page.unmount();
});

test("picking a character shows the pet with it; None hides it", async () => {
  const page = await renderPage({ path: "/settings/chief-pet" });
  await settle();
  const pick = async (id: string) => {
    await act(async () => card(page.container).querySelector<HTMLElement>(`[data-pet="${id}"]`)!.click());
    await settle();
  };
  await pick("fox");
  expect(shown(card(page.container))).toEqual({ enabled: true, character: "Fox" });
  expect(checked(card(page.container))).toBe("fox");
  await pick("none");
  // None keeps the character for next time.
  expect(shown(card(page.container))).toEqual({ enabled: false, character: "Fox" });
  expect(checked(card(page.container))).toBe("none");
  page.unmount();
});

test("Show Pet and Hide Pet turn the pet on and off with its character kept", async () => {
  const page = await renderPage({ path: "/settings/chief-pet", mock: { values: { "home.chiefPetMascot": "moon" } } });
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
