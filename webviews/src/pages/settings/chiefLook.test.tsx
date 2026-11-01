// Settings > Chief > Look: how the Chief looks is one glass card: the pet's preview with Show Pet,
// the characters (every Chief surface wears the chosen one), and the chat's Bubble Style, which
// before stood alone below the pet as a one-row "Chief Chat" card, with the bubble colors every chat
// starts with (`home.bubbleColors.*`) under it.
import { afterAll, expect, test } from "bun:test";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { changeValue, click, fire, renderPage, settle } = await import("./testing");
const { CHIEF_PET_MASCOTS } = await import("./components/ChiefPetCard");

const look = (container: HTMLElement) => container.querySelector<HTMLElement>('[data-card="chief-pet"]')!;
const BUBBLE_COLORS = ["sent", "sentText", "received", "receivedText"].map((role) => `home.bubbleColors.${role}`);

test("Look is one glass card with the pet, the characters and Bubble Style", async () => {
  const page = await renderPage({ path: "/settings/chief" });
  await settle();
  const card = look(page.container);
  expect(card.classList.contains("ui-glass")).toBe(true);
  expect(card.querySelector(".group-title")!.textContent).toBe("Look");
  expect(card.querySelector(".chief-pet-preview")).not.toBeNull();
  expect(card.querySelectorAll(".chief-pet-choice")).toHaveLength(CHIEF_PET_MASCOTS.length);
  expect(card.querySelector('[data-row-key="home.chiefBubbleStyle"]')).not.toBeNull();
  const colors = [...card.querySelectorAll('[data-row-key^="home.bubbleColors."]')].map((row) =>
    row.getAttribute("data-row-key"),
  );
  expect(colors).toEqual(BUBBLE_COLORS);
  page.unmount();
});

test("Bubble Style shows once, in Look: no Chief Chat card of its own", async () => {
  const page = await renderPage({ path: "/settings/chief" });
  await settle();
  expect(page.container.querySelectorAll('[data-row-key="home.chiefBubbleStyle"]')).toHaveLength(1);
  expect(page.container.querySelector('[data-group="settings.group.chiefChat"]')).toBeNull();
  page.unmount();
});

test("a search result for Bubble Style lands on its row in Look", async () => {
  const page = await renderPage({ path: "/settings/chief?focus=home.chiefBubbleStyle" });
  await settle();
  const row = look(page.container).querySelector<HTMLElement>('[data-row-key="home.chiefBubbleStyle"]')!;
  expect(row.contains(document.activeElement)).toBe(true);
  page.unmount();
});

test("search renders Bubble Style in the Look card", async () => {
  const page = await renderPage({ path: "/settings/chief" });
  await changeValue(page.container.querySelector<HTMLInputElement>("[data-settings-search]")!, "Bubble Style");
  await settle();
  const result = page.container.querySelector<HTMLElement>('[data-search-results] [data-card="chief-pet"]');
  expect(result).not.toBeNull();
  expect(result?.querySelector('[data-row-key="home.chiefBubbleStyle"]')).not.toBeNull();
  expect(result?.querySelector('[data-row-key="home.chiefBubbleStyle"] mark')?.textContent).toBe("Bubble");
  // The unset bubble colors read "Bubble Style" (their default label), so they match too, under it.
  const rows = [...result!.querySelectorAll("[data-row-key]")].map((row) => row.getAttribute("data-row-key"));
  expect(rows).toEqual(["home.chiefBubbleStyle", ...BUBBLE_COLORS]);
  expect(page.container.querySelector('[data-search-results] [data-group="settings.group.chiefChat"]')).toBeNull();
  page.unmount();
});

test("Show Only Changed keeps unchanged pet rows out of the Look card", async () => {
  const page = await renderPage({
    path: "/settings/chief",
    mock: { values: { "home.chiefBubbleStyle": "theme" } },
  });
  await click(page.container.querySelector<HTMLElement>("[data-changed-only]")!);
  await settle();
  const result = page.container.querySelector<HTMLElement>('[data-search-results] [data-card="chief-pet"]');
  expect(result).not.toBeNull();
  expect(result?.querySelector('[data-row-key="home.chiefBubbleStyle"]')).not.toBeNull();
  expect(result?.querySelector('[data-row-key="home.chiefPetEnabled"]')).toBeNull();
  expect(result?.querySelector('[data-row-key="home.chiefPetMascot"]')).toBeNull();
  expect(result?.querySelectorAll(".chief-pet-choice")).toHaveLength(0);
  expect(result?.querySelectorAll("[data-row-key]")).toHaveLength(1);
  page.unmount();
});

test("search result rows for the pet controls can receive keyboard focus", async () => {
  const page = await renderPage({ path: "/settings/chief" });
  const search = page.container.querySelector<HTMLInputElement>("[data-settings-search]")!;
  await changeValue(search, "Show Chief Pet");
  const enabled = page.container.querySelector<HTMLElement>(
    '[data-search-results] [data-row-key="home.chiefPetEnabled"]',
  )!;
  enabled.focus();
  expect(document.activeElement).toBe(enabled);
  await changeValue(search, "Character");
  const mascot = page.container.querySelector<HTMLElement>(
    '[data-search-results] [data-row-key="home.chiefPetMascot"]',
  )!;
  mascot.focus();
  expect(document.activeElement).toBe(mascot);
  page.unmount();
});

test("the Show Chief Pet search row toggles with Space", async () => {
  const page = await renderPage({ path: "/settings/chief" });
  const search = page.container.querySelector<HTMLInputElement>("[data-settings-search]")!;
  await changeValue(search, "Show Chief Pet");
  const enabled = page.container.querySelector<HTMLElement>(
    '[data-search-results] [data-row-key="home.chiefPetEnabled"]',
  )!;
  enabled.focus();
  await fire(enabled, "keydown", { key: " " });
  expect(page.provider.log.filter((entry) => entry.op === "cmux.settings.set").at(-1)?.params).toMatchObject({
    key: "home.chiefPetEnabled",
    value: true,
  });
  page.unmount();
});
