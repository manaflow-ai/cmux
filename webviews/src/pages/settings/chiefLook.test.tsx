// Settings > Chief > Look: how the Chief looks is one glass card: the pet's preview with Show Pet,
// the characters (every Chief surface wears the chosen one), and the chat's Bubble Style, which
// before stood alone below the pet as a one-row "Chief Chat" card.
import { afterAll, expect, test } from "bun:test";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { changeValue, renderPage, settle } = await import("./testing");

const look = (container: HTMLElement) => container.querySelector<HTMLElement>('[data-card="chief-pet"]')!;

test("Look is one glass card with the pet, the characters and Bubble Style", async () => {
  const page = await renderPage({ path: "/settings/chief" });
  await settle();
  const card = look(page.container);
  expect(card.classList.contains("ui-glass")).toBe(true);
  expect(card.querySelector(".group-title")!.textContent).toBe("Look");
  expect(card.querySelector(".chief-pet-preview")).not.toBeNull();
  expect(card.querySelectorAll(".chief-pet-choice")).toHaveLength(9);
  expect(card.querySelector('[data-row-key="home.chiefBubbleStyle"]')).not.toBeNull();
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
  expect(page.container.querySelector('[data-search-results] [data-group="settings.group.chiefChat"]')).toBeNull();
  page.unmount();
});
