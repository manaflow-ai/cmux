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

// Regression (gallery `*-group-N` variants never scrolled): the page's own query string is not
// part of the route, so `?focus=<key>` in the fragment names the key exactly.
test("the route comes from the fragment alone, never the page's query string", async () => {
  const { createFragmentHistory } = await import("./router");
  const { parseLocation } = await import("./router");
  const url = new URL(
    "https://host.test/frame.html?entry=pages.settings&variant=x#/settings/general?focus=app.quitBehavior",
  );
  const fake = {
    location: { hash: url.hash, search: url.search, pathname: url.pathname },
    history: { state: null, pushState() {}, replaceState() {} },
    addEventListener() {},
    removeEventListener() {},
  } as unknown as Window;
  const history = createFragmentHistory(fake);
  expect(parseLocation(history.location.href)).toEqual({ section: "general", focus: "app.quitBehavior" });
  expect(history.createHref("/settings/browser")).toBe("/frame.html?entry=pages.settings&variant=x#/settings/browser");
});
