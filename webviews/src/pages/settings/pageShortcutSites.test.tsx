// browser.pageShortcutSites (a string_map row, CMUX-641): each site's value is a menu of page or cmux,
// never ask (only every site's default asks), and the sites sit in their own box, which scrolls when the
// list is long, with the add line under it.
import { afterAll, expect, test } from "bun:test";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { renderPage, rowElement } = await import("./testing");

const KEY = "browser.pageShortcutSites";

test("a site answers page or cmux, and the sites scroll apart from the add line", async () => {
  const sites = Object.fromEntries(Array.from({ length: 30 }, (_, index) => [`site${index}.example`, "page"]));
  const page = await renderPage({ path: "/settings/browser", mock: { values: { [KEY]: sites } } });
  const row = rowElement(page.container, KEY);
  const options = [...row.querySelectorAll('[data-map-key="site0.example"] option')].map((option) =>
    option.getAttribute("value"),
  );
  expect(options).toEqual(["page", "cmux"]);
  const box = row.querySelector("[data-string-map-items]")!;
  expect(box.querySelectorAll("[data-map-key]").length).toBe(30);
  // The add line is outside the box: it stays in place however long the list gets.
  expect(box.querySelector("input[data-map-new-key]")).toBeNull();
  expect(row.querySelector("input[data-map-new-key]")).not.toBeNull();
});
