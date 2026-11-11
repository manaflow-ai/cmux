// Every category page with three or more titled cards shows one jump bar of them, pinned at the
// top on glass; Personalization shows its parts in the same bar. A button scrolls its card into
// view; a page with fewer cards shows no bar.
import { afterAll, expect, test } from "bun:test";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { click, renderPage, settle } = await import("./testing");
const { categoryById } = await import("./categories");
const { text } = await import("./strings");

const labels = (container: HTMLElement) =>
  [...container.querySelectorAll<HTMLElement>("[data-jump-bar] [data-jump]")].map((button) => button.textContent);

test("a page with many cards lists each titled card in its jump bar, in page order", async () => {
  const page = await renderPage({ path: "/settings/sidebar" });
  await settle();
  const drawn = [...page.container.querySelectorAll<HTMLElement>("[data-group] .group-title")].map(
    (title) => title.textContent,
  );
  expect(labels(page.container)).toEqual(drawn);
  expect(labels(page.container).length).toBeGreaterThanOrEqual(3);
  expect(page.container.querySelector("[data-jump-bar]")!.getAttribute("aria-label")).toBe(
    text(categoryById("sidebar").title),
  );
  page.unmount();
});

test("a jump scrolls its card into view", async () => {
  const page = await renderPage({ path: "/settings/appearance" });
  await settle();
  const scrolled: string[] = [];
  const original = HTMLElement.prototype.scrollIntoView;
  HTMLElement.prototype.scrollIntoView = function (this: HTMLElement) {
    if (this.dataset.group) scrolled.push(this.dataset.group);
  };
  try {
    const button = page.container.querySelectorAll<HTMLElement>("[data-jump-bar] [data-jump]")[2]!;
    await click(button);
    expect(scrolled).toEqual([button.dataset.jump!]);
    // The jumped-to card stays current, though the page may not scroll it to the top.
    expect(button.getAttribute("aria-current")).toBe("true");
  } finally {
    HTMLElement.prototype.scrollIntoView = original;
  }
  page.unmount();
});

test("a page with fewer than three titled cards shows no jump bar", async () => {
  const page = await renderPage({ path: "/settings/theme" });
  await settle();
  expect(page.container.querySelector("[data-jump-bar]")).toBeNull();
  page.unmount();
});

test("Personalization lists its parts in the same jump bar", async () => {
  const page = await renderPage({ path: "/settings/personalization" });
  await settle();
  expect(page.container.querySelectorAll("[data-jump-bar]")).toHaveLength(1);
  expect(labels(page.container).length).toBe(5);
  page.unmount();
});
