// The Theme section (P3, P4): the preview draws the theme in effect, the picker writes
// appearance.theme, Match System Appearance writes a light/dark pair, a narrower scope's theme
// shows inline with a Reset that clears that level, and the app theme is the host's `app` level.
import { afterAll, afterEach, expect, test } from "bun:test";
import { installDom } from "./testDom";
import type { Rendered } from "./testing";

const restore = installDom();
afterAll(() => restore());
const { click, ops, renderPage, run } = await import("./testing");

let page: Rendered | null = null;
afterEach(() => {
  page?.unmount();
  page = null;
});

const theme = (page: Rendered) => page.container.querySelector<HTMLElement>('[data-card="theme"]')!;

test("the preview shows the configured theme and its derived contrast", async () => {
  page = await renderPage({ path: "/settings/theme", mock: { values: { "appearance.theme": "Dracula" } } });
  expect(theme(page).querySelector("[data-theme-preview]")?.getAttribute("data-theme-preview")).toBe("Dracula");
  expect(theme(page).querySelector("[data-contrast]")?.textContent).toMatch(/text \d+(\.\d)?:1/);
  expect(ops(page.provider, "cmux.settings.theme.colors").length).toBe(1);
});

test("an override in a narrower scope shows inline, and Reset clears that level", async () => {
  page = await renderPage({ path: "/settings/theme" });
  const note = theme(page).querySelector<HTMLElement>('[data-override="workspace"]')!;
  expect(note.textContent).toContain("Overridden in this workspace by Dracula");
  expect(page.container.querySelector('input[name="theme-level"]')).toBeNull();
  await click(note.querySelector("button")!);
  expect(ops(page.provider, "cmux.settings.theme.set")).toEqual([{ level: "workspace", spec: null }]);
  expect(theme(page).querySelector('[data-override="workspace"]')).toBeNull();
});

test("picking a theme writes appearance.theme; Match System Appearance writes a pair", async () => {
  page = await renderPage({ path: "/settings/theme" });
  await run(() => page!.store.set("appearance.theme", "Tokyo Night"));
  expect(theme(page).querySelector("[data-theme-picker]")?.textContent).toContain("Tokyo Night");
  await click(theme(page).querySelector('[data-theme-row="match"] [role=switch]')!);
  const writes = ops(page.provider, "cmux.settings.set");
  expect(writes.at(-1)).toEqual({ key: "appearance.theme", value: expect.stringMatching(/^light:.+,dark:.+$/) });
  expect(theme(page).querySelectorAll("[data-theme-picker]").length).toBe(3);
  await click(theme(page).querySelector('[data-theme-row="match"] [role=switch]')!);
  expect(ops(page.provider, "cmux.settings.set").at(-1)).toEqual({
    key: "appearance.theme",
    value: expect.not.stringContaining(":"),
  });
});

test("the app theme (appearance.appTheme) matches the terminal theme until it names one", async () => {
  page = await renderPage({ path: "/settings/theme" });
  const app = () => theme(page!).querySelector<HTMLElement>('[data-theme-row="app"]')!;
  expect(app().textContent).toContain("Match Terminal Theme");
  await run(() => page!.store.set("appearance.appTheme", "Gruvbox Dark"));
  expect(app().textContent).toContain("Gruvbox Dark");
  expect(ops(page.provider, "cmux.settings.set").at(-1)).toEqual({ key: "appearance.appTheme", value: "Gruvbox Dark" });
  await run(() => page!.store.reset("appearance.appTheme"));
  expect(app().textContent).toContain("Match Terminal Theme");
});

test("an unset theme previews the Ghostty config's own colors from the host", async () => {
  page = await renderPage({ path: "/settings/theme" });
  const preview = theme(page).querySelector("[data-theme-preview]")!;
  expect(preview.getAttribute("data-theme-preview")).toBe("Use Ghostty Config");
  // The mock's config is Apple System Colors (#1e1e1e); the preview draws its background.
  expect(preview.querySelector("rect")?.getAttribute("fill")).toBe("#1e1e1e");
});
