import { afterAll, afterEach, expect, test } from "bun:test";
import { installDom } from "./testDom";
import type { Rendered } from "./testing";

const restore = installDom();
afterAll(() => restore());
const { renderPage, run } = await import("./testing");

let page: Rendered | null = null;
afterEach(() => {
  page?.unmount();
  page = null;
});

const current = (page: Rendered) =>
  [...page.container.querySelectorAll("[data-section-link][aria-current]")].map((link) =>
    link.getAttribute("data-section-link"),
  );

// The host opens a route on a page it keeps (Customize Appearance… on an open Settings tab): the
// section list must mark the section the page shows, never the one it showed before.
test("a route the host opens moves the section list's mark with the page", async () => {
  page = await renderPage({ path: "/settings/general" });
  expect(current(page)).toEqual(["general"]);
  await run(() => page!.history.push("/settings/appearance"));
  expect(page.container.querySelector("[data-section]")?.getAttribute("data-section")).toBe("appearance");
  expect(current(page)).toEqual(["appearance"]);
  await run(() => page!.history.push("/settings/appearance?focus=appearance.density"));
  expect(current(page)).toEqual(["appearance"]);
});
