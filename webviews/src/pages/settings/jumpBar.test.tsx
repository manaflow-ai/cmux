// Only Personalization shows a jump bar (standup 2026-11-11: "top section bar only on
// Personalization"): one bar of its parts, pinned at the top on glass. A button scrolls its part
// into view and marks it current. A category page shows no bar, however many cards it has.
import { afterAll, expect, test } from "bun:test";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { click, renderPage, settle } = await import("./testing");
const { t } = await import("./strings");

const labels = (container: HTMLElement) =>
  [...container.querySelectorAll<HTMLElement>("[data-jump-bar] [data-jump]")].map((button) => button.textContent);

test("Personalization lists each part in its jump bar, in page order", async () => {
  const page = await renderPage({ path: "/settings/personalization" });
  await settle();
  const drawn = [...page.container.querySelectorAll<HTMLElement>("[data-part] .personalization-part-title")].map(
    (title) => title.textContent,
  );
  expect(page.container.querySelectorAll("[data-jump-bar]")).toHaveLength(1);
  expect(labels(page.container)).toEqual(drawn);
  expect(labels(page.container).length).toBe(5);
  expect(page.container.querySelector("[data-jump-bar]")!.getAttribute("aria-label")).toBe(
    t("settingsPage.personalization.jump"),
  );
  page.unmount();
});

test("a jump scrolls its part into view and marks it current", async () => {
  const page = await renderPage({ path: "/settings/personalization" });
  await settle();
  const scrolled: string[] = [];
  const original = HTMLElement.prototype.scrollIntoView;
  HTMLElement.prototype.scrollIntoView = function (this: HTMLElement) {
    if (this.dataset.part) scrolled.push(this.dataset.part);
  };
  try {
    const button = page.container.querySelectorAll<HTMLElement>("[data-jump-bar] [data-jump]")[2]!;
    await click(button);
    await settle();
    expect(scrolled).toEqual([button.dataset.jump!]);
    // The jumped-to part stays current, though the page may not scroll it to the top.
    const current = page.container.querySelector<HTMLElement>('[data-jump-bar] [data-jump][aria-current="true"]');
    expect(current?.dataset.jump).toBe(button.dataset.jump);
  } finally {
    HTMLElement.prototype.scrollIntoView = original;
  }
  page.unmount();
});

test("a category page with many titled cards shows no jump bar", async () => {
  for (const path of ["/settings/sidebar", "/settings/appearance"]) {
    const page = await renderPage({ path });
    await settle();
    expect(page.container.querySelectorAll("[data-group] .group-title").length).toBeGreaterThanOrEqual(3);
    expect(page.container.querySelector("[data-jump-bar]")).toBeNull();
    page.unmount();
  }
});
