import { afterAll, afterEach, expect, test } from "bun:test";
import { FakeTransport } from "./fakeTransport";
import { installDom } from "./testDom";
import type { Rendered } from "./testing";

const restore = installDom();
afterAll(() => restore());
const { changeValue, fire, renderPage } = await import("./testing");

let page: Rendered | null = null;
afterEach(() => {
  page?.unmount();
  page = null;
});

const search = (page: Rendered) => page.container.querySelector<HTMLInputElement>("[data-settings-search]")!;
const resultKeys = (page: Rendered) =>
  [...page.container.querySelectorAll("[data-search-results] [data-row-key]")].map((row) =>
    row.getAttribute("data-row-key"),
  );

test("opening the page focuses the search field", async () => {
  page = await renderPage();
  expect(document.activeElement).toBe(search(page));
});

test("search finds rows by keyword across sections, highlighted and editable", async () => {
  page = await renderPage({ path: "/settings/general" });
  await changeValue(search(page), "transparency");
  expect(resultKeys(page)).toEqual(["appearance.backgroundOpacity", "appearance.backgroundBlur"]);
  await changeValue(search(page), "font");
  const keys = resultKeys(page);
  expect(keys).toContain("terminal.fontFamily");
  expect(keys).toContain("appearance.metrics.chromeFontSize");
  expect(page.container.querySelector("[data-search-results] mark")?.textContent?.toLowerCase()).toBe("font");
  expect(
    page.container.querySelector('[data-search-results] [data-row-key="terminal.fontSize"] input.number'),
  ).not.toBeNull();
});

test("search finds rows by current value", async () => {
  const fake = new FakeTransport({
    values: { "browser.newTabPage": "https://start.cmux.dev", "appearance.backgroundBlur": "glass-clear" },
  });
  page = await renderPage({ fake });
  await changeValue(search(page), "start.cmux");
  expect(resultKeys(page)).toEqual(["browser.newTabPage"]);
  await changeValue(search(page), "clear glass");
  expect(resultKeys(page)).toEqual(["appearance.backgroundBlur"]);
  await changeValue(search(page), "zzzz-no-match");
  expect(page.container.querySelector(".empty")).not.toBeNull();
});

test("Return reveals the row in its section and focuses its control; Esc clears, then focuses the list", async () => {
  page = await renderPage({ path: "/settings/general" });
  await changeValue(search(page), "opacity");
  await fire(search(page), "keydown", { key: "Enter" });
  expect(page.history.location.pathname).toBe("/settings/appearance");
  expect(page.history.location.search).toBe("?focus=appearance.backgroundOpacity");
  expect(search(page).value).toBe("");
  expect(page.container.querySelector('[data-section="appearance"]')).not.toBeNull();
  const focused = document.activeElement as HTMLElement;
  expect(focused.closest("[data-row-key]")?.getAttribute("data-row-key")).toBe("appearance.backgroundOpacity");

  await changeValue(search(page), "abc");
  await fire(search(page), "keydown", { key: "Escape" });
  expect(search(page).value).toBe("");
  await fire(search(page), "keydown", { key: "Escape" });
  expect((document.activeElement as HTMLElement).getAttribute("data-section-link")).toBe("appearance");
});

test("Up/Down move between rows, Space toggles, Cmd-Backspace resets, Cmd-[ goes back", async () => {
  page = await renderPage({ path: "/settings/general" });
  await fire(search(page), "keydown", { key: "ArrowDown" });
  const first = document.activeElement as HTMLElement;
  expect(first.getAttribute("data-row-key")).toBe("history.terminalCommands");
  await fire(first, "keydown", { key: " " });
  expect(page.fake.log.filter((entry) => entry.op === "settings.set").map((entry) => entry.params)).toEqual([
    { key: "history.terminalCommands", value: true },
  ]);
  await fire(first, "keydown", { key: "Backspace", metaKey: true });
  expect(page.fake.log.filter((entry) => entry.op === "settings.reset").length).toBe(1);
  await fire(first, "keydown", { key: "ArrowDown" });
  expect((document.activeElement as HTMLElement).getAttribute("data-row-key")).toBe("window.titlebar");

  await fire(page.container.querySelector('[data-section-link="browser"]')!, "click");
  expect(page.history.location.pathname).toBe("/settings/browser");
  await fire(document.body, "keydown", { key: "[", metaKey: true });
  expect(page.history.location.pathname).toBe("/settings/general");
  await fire(document.body, "keydown", { key: "]", metaKey: true });
  expect(page.history.location.pathname).toBe("/settings/browser");
  await fire(document.body, "keydown", { key: "f", metaKey: true });
  expect(document.activeElement).toBe(search(page));
});
