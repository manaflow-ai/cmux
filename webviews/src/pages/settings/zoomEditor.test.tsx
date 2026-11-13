import { afterAll, afterEach, expect, test } from "bun:test";
import { installDom } from "./testDom";
import type { Rendered } from "./testing";

const restore = installDom();
afterAll(() => restore());
const { changeValue, ops, renderPage, resetRow, rowElement, run } = await import("./testing");

const KEY = "app.uiScale";
let page: Rendered | null = null;
afterEach(() => {
  page?.unmount();
  page = null;
});

function row() {
  return rowElement(page!.container, KEY);
}

function menu() {
  return row().querySelector<HTMLSelectElement>("select.ui-select-native")!;
}

test("App Zoom is a percentage menu that writes a numeric scale without previews", async () => {
  page = await renderPage({ path: "/settings/appearance", mock: { values: { [KEY]: 1 } } });
  expect(row().querySelector("input")).toBeNull();
  expect(row().querySelector(".ui-select-button")?.textContent).toBe("100%");
  expect([...menu().options].map((option) => option.textContent)).toEqual([
    "25%",
    "33%",
    "50%",
    "67%",
    "75%",
    "80%",
    "90%",
    "100%",
    "110%",
    "125%",
    "150%",
    "175%",
    "200%",
    "250%",
    "300%",
    "400%",
    "500%",
  ]);
  await changeValue(menu(), "1.25");
  expect(ops(page.provider, "cmux.settings.set")).toEqual([{ key: KEY, value: 1.25 }]);
  expect(ops(page.provider, "cmux.settings.preview")).toEqual([]);
  expect(row().querySelector(".ui-select-button")?.textContent).toBe("125%");
  for (const scale of [0.25, 0.33, 0.67, 5]) await changeValue(menu(), String(scale));
  expect(ops(page.provider, "cmux.settings.set").slice(1)).toEqual([
    { key: KEY, value: 0.25 },
    { key: KEY, value: 0.33 },
    { key: KEY, value: 0.67 },
    { key: KEY, value: 5 },
  ]);
  expect(row().querySelector(".ui-select-button")?.textContent).toBe("500%");
  await resetRow(page.container, KEY);
  expect(row().querySelector(".ui-select-button")?.textContent).toBe("100%");
});

test("App Zoom preserves a custom scale and follows external changes", async () => {
  page = await renderPage({ path: "/settings/appearance", mock: { values: { [KEY]: 1.23 } } });
  expect(menu().value).toBe("1.23");
  expect(row().querySelector(".ui-select-button")?.textContent).toBe("123%");
  expect(ops(page.provider, "cmux.settings.set")).toEqual([]);
  await run(() => page!.provider.externalSet(KEY, 0.92));
  expect(menu().value).toBe("0.92");
  expect(row().querySelector(".ui-select-button")?.textContent).toBe("92%");
});

test("a managed App Zoom disables the dropdown", async () => {
  page = await renderPage({
    path: "/settings/appearance",
    mock: { managed: { [KEY]: { value: 1.1, source: "device", reason: "Device policy" } } },
  });
  expect(menu().disabled).toBe(true);
  expect(row().querySelector<HTMLButtonElement>(".ui-select-button")?.disabled).toBe(true);
  expect(row().querySelector(".ui-select-button")?.textContent).toBe("110%");
});
