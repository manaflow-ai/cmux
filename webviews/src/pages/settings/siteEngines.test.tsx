// browser.siteEngines (a string_map row): the page lists each site with its engine, changes a
// site's engine, removes a site and adds one; a site that is not one is refused before any write.
import { afterAll, expect, test } from "bun:test";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { changeValue, click, ops, renderPage, rowElement, settle } = await import("./testing");

const KEY = "browser.siteEngines";

function sites(row: HTMLElement): string[] {
  return [...row.querySelectorAll("[data-map-key]")].map((item) => item.getAttribute("data-map-key")!);
}

function engineOf(row: HTMLElement, site: string): string {
  return row.querySelector<HTMLSelectElement>(`[data-map-key="${site}"] select`)!.value;
}

test("site engines are listed, changed, removed and added", async () => {
  const page = await renderPage({
    path: "/settings/browser",
    mock: { values: { [KEY]: { "spotify.com": "webkit", "example.com": "chromium" } } },
  });
  const row = () => rowElement(page.container, KEY);
  expect(sites(row())).toEqual(["example.com", "spotify.com"]);
  expect(engineOf(row(), "example.com")).toBe("chromium");
  // The engine menu offers the engines browser.defaultEngine offers.
  const options = [...row().querySelectorAll('[data-map-key="example.com"] option')].map((option) =>
    option.getAttribute("value"),
  );
  expect(options).toEqual(["chromium", "webkit"]);

  await changeValue(row().querySelector<HTMLSelectElement>('[data-map-key="example.com"] select')!, "webkit");
  expect(ops(page.provider, "cmux.settings.set").at(-1)).toEqual({
    key: KEY,
    value: { "example.com": "webkit", "spotify.com": "webkit" },
  });

  await click(row().querySelector('[data-map-key="spotify.com"] button[aria-label^="Remove"]')!);
  expect(ops(page.provider, "cmux.settings.set").at(-1)).toEqual({ key: KEY, value: { "example.com": "webkit" } });

  await changeValue(row().querySelector<HTMLInputElement>("input[data-map-new-key]")!, "netflix.com");
  await changeValue(row().querySelector<HTMLSelectElement>("[data-map-new-value] select")!, "webkit");
  await click(row().querySelector("button[data-map-add]")!);
  await settle();
  expect(ops(page.provider, "cmux.settings.set").at(-1)).toEqual({
    key: KEY,
    value: { "example.com": "webkit", "netflix.com": "webkit" },
  });
  expect(sites(row())).toEqual(["example.com", "netflix.com"]);
  page.unmount();
});

test("a site with a space is refused and nothing is written", async () => {
  const page = await renderPage({ path: "/settings/browser", mock: { values: { [KEY]: {} } } });
  const row = () => rowElement(page.container, KEY);
  await changeValue(row().querySelector<HTMLInputElement>("input[data-map-new-key]")!, "not a site");
  await click(row().querySelector("button[data-map-add]")!);
  expect(ops(page.provider, "cmux.settings.set")).toEqual([]);
  expect(row().querySelector('[role="alert"]')).not.toBeNull();
  page.unmount();
});
