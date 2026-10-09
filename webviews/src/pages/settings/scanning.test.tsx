// Round-1 tournament design A for Settings: a section's name finds its settings, a changed setting is
// marked next to its title, and a row's error replaces its help line (never both).
import { afterAll, afterEach, expect, test } from "bun:test";
import { installDom } from "./testDom";
import type { Rendered } from "./testing";

const restore = installDom();
afterAll(() => restore());
const { changeValue, renderPage, rowElement, run } = await import("./testing");

let page: Rendered | null = null;
afterEach(() => {
  page?.unmount();
  page = null;
});

const search = (page: Rendered) => page.container.querySelector<HTMLInputElement>("[data-settings-search]")!;
const resultKeys = (page: Rendered) =>
  [...page.container.querySelectorAll("[data-search-results] [data-row-key]:not([data-filtered])")].map((row) =>
    row.getAttribute("data-row-key"),
  );

test("a search for a section's name lists that section's settings", async () => {
  page = await renderPage({ path: "/settings/general" });
  // "Dismissal" is a group title in Notifications; this row's own title, help, key and keywords
  // never say it, so it matches only through its group.
  await changeValue(search(page), "dismissal");
  expect(resultKeys(page)).toContain("notifications.timeoutSeconds");
});

test("a changed setting is marked next to its title, with an accessible name; a default one is not", async () => {
  page = await renderPage({ path: "/settings/browser", mock: { values: { "browser.hibernation": 30 } } });
  const changed = rowElement(page.container, "browser.hibernation");
  expect(changed.hasAttribute("data-customized")).toBe(true);
  expect(changed.querySelector("[data-row-changed]")?.textContent).toBe("Changed");
  const plain = rowElement(page.container, "browser.newTabPage");
  expect(plain.hasAttribute("data-customized")).toBe(false);
  expect(plain.querySelector("[data-row-changed]")).toBeNull();
});

test("a row's error replaces its help line while it shows", async () => {
  page = await renderPage({ path: "/settings/browser" });
  const row = () => rowElement(page!.container, "browser.hibernation");
  expect(row().querySelector(".row-help")).not.toBeNull();
  await run(() => page!.store.set("browser.hibernation", -5));
  expect(row().querySelector(".row-error")).not.toBeNull();
  expect(row().querySelector(".row-help")).toBeNull();
});
