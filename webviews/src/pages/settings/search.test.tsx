import { afterAll, afterEach, expect, test } from "bun:test";
import { installDom } from "./testDom";
import type { Rendered } from "./testing";

const restore = installDom();
afterAll(() => restore());
const { changeValue, fire, ops, renderPage, rowElement, run } = await import("./testing");

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
  expect(resultKeys(page)).toEqual(
    expect.arrayContaining(["appearance.backgroundOpacity", "appearance.backgroundBlur"]),
  );
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
  page = await renderPage({
    mock: { values: { "browser.newTabPage": "https://start.cmux.dev", "appearance.backgroundBlur": "glass-clear" } },
  });
  await changeValue(search(page), "start.cmux");
  expect(resultKeys(page)).toEqual(["browser.newTabPage"]);
  await changeValue(search(page), "clear glass");
  expect(resultKeys(page)).toContain("appearance.backgroundBlur");
  await changeValue(search(page), "zzzz-no-match");
  expect(page.container.querySelector(".empty")).not.toBeNull();
});

test("Return reveals the row in its section and focuses its control; Esc clears, then focuses the list", async () => {
  page = await renderPage({ path: "/settings/general" });
  await changeValue(search(page), "appearance.backgroundOpacity");
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

test("Up/Down move between rows, Space toggles; dispatcher commands reset, go back and find; chords do nothing", async () => {
  page = await renderPage({ path: "/settings/general" });
  const sectionRows = [
    ...page.container.querySelectorAll<HTMLElement>(".content [data-row-key], .content [data-action-row]"),
  ];
  await fire(search(page), "keydown", { key: "ArrowDown" });
  expect(document.activeElement).toBe(sectionRows[0]!);
  // A toggle row by key, so a new row in General does not change what this test drives.
  const first = rowElement(page.container, "history.terminalCommands");
  first.focus();
  await fire(first, "keydown", { key: " " });
  expect(ops(page.provider, "cmux.settings.set")).toEqual([{ key: "history.terminalCommands", value: true }]);
  // The page handles no Cmd chords: the app's key dispatcher owns them.
  await fire(first, "keydown", { key: "Backspace", metaKey: true });
  expect(ops(page.provider, "cmux.settings.reset")).toEqual([]);
  await run(() => page!.provider.sendCommand("reset"));
  expect(ops(page.provider, "cmux.settings.reset")).toEqual([{ key: "history.terminalCommands" }]);
  // The next row in the section's rendered order (the schema decides which one it is).
  const rows = [...page.container.querySelectorAll(".content [data-row-key], .content [data-action-row]")];
  const next = rows[rows.indexOf(first) + 1]!;
  await fire(first, "keydown", { key: "ArrowDown" });
  expect(document.activeElement).toBe(next);

  await fire(page.container.querySelector('[data-section-link="browser"]')!, "click");
  expect(page.history.location.pathname).toBe("/settings/browser");
  await fire(document.body, "keydown", { key: "[", metaKey: true });
  expect(page.history.location.pathname).toBe("/settings/browser");
  await run(() => page!.provider.sendCommand("back"));
  expect(page.history.location.pathname).toBe("/settings/general");
  await run(() => page!.provider.sendCommand("forward"));
  expect(page.history.location.pathname).toBe("/settings/browser");
  await fire(document.body, "keydown", { key: "f", metaKey: true });
  expect(document.activeElement).not.toBe(search(page));
  await run(() => page!.provider.sendCommand("find"));
  expect(document.activeElement).toBe(search(page));
});
