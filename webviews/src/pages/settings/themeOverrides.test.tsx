// Colors the Ghostty config sets itself win over every theme. The Theme section names them with
// their file and lines, and Let Themes Set Colors asks the host to turn the lines off.
import { afterAll, afterEach, expect, test } from "bun:test";
import { installDom } from "./testDom";
import type { Rendered } from "./testing";

const restore = installDom();
afterAll(() => restore());
const { click, ops, renderPage } = await import("./testing");

let page: Rendered | null = null;
afterEach(() => {
  page?.unmount();
  page = null;
});

const notice = (page: Rendered) => page.container.querySelector<HTMLElement>("[data-theme-overrides]");
const action = (page: Rendered, name: "release" | "open") =>
  notice(page)!.querySelector<HTMLButtonElement>(`[data-theme-overrides-action="${name}"]`)!;
const themeOverrides = [
  { key: "background", file: "~/.config/ghostty/config", line: 2 },
  { key: "foreground", file: "~/.config/ghostty/config", line: 3 },
];

test("no notice when the Ghostty config sets no colors", async () => {
  page = await renderPage({ path: "/settings/theme" });
  expect(notice(page)).toBeNull();
});

test("the notice names the keys, the file and the lines", async () => {
  page = await renderPage({ path: "/settings/theme", mock: { themeOverrides } });
  const text = notice(page)!.textContent!;
  expect(text).toContain("background and foreground");
  expect(text).toContain("~/.config/ghostty/config, lines 2, 3");
});

test("Let Themes Set Colors asks the host and the notice goes", async () => {
  page = await renderPage({ path: "/settings/theme", mock: { themeOverrides } });
  await click(action(page, "release"));
  expect(ops(page.provider, "cmux.settings.theme.overrides.release")).toEqual([{}]);
  expect(notice(page)).toBeNull();
});

test("Open Ghostty Config asks the host to open the file", async () => {
  page = await renderPage({ path: "/settings/theme", mock: { themeOverrides } });
  await click(action(page, "open"));
  expect(ops(page.provider, "cmux.settings.theme.overrides.open")).toEqual([{}]);
});
