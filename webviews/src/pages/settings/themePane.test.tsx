// Settings > Theme is one card (Leo, 2026-10-19: "why are these different"): the terminal theme and
// the app theme, each with Match System Appearance, then the accent. The schema's App Theme group
// lists the same keys, so the page drew them twice, the second time with a plain "Filter" list and a
// menu for the accent. Every theme choice is now the one ThemePicker, the accent is a swatch popup in
// its style, and every row keeps its Reset slot.
import { afterAll, afterEach, expect, test } from "bun:test";
import { installDom } from "./testDom";
import type { Rendered } from "./testing";

const restore = installDom();
afterAll(() => restore());
const { changeValue, click, fire, ops, renderPage, run } = await import("./testing");
const { t } = await import("./strings");

let page: Rendered | null = null;
afterEach(() => {
  page?.unmount();
  page = null;
});

const card = (page: Rendered) => page.container.querySelector<HTMLElement>('[data-card="theme"]')!;
const themeRow = (page: Rendered, kind: string) => card(page).querySelector<HTMLElement>(`[data-theme-row="${kind}"]`);
const STUDIO_KEYS = ["appearance.theme", "appearance.appTheme", "appearance.accent"];

test("the Theme page draws each theme key once, in one card, with no second App Theme group", async () => {
  page = await renderPage({ path: "/settings/theme" });
  const titles = [...page.container.querySelectorAll(".group-title")].map((title) => title.textContent);
  expect(titles).not.toContain("App Theme");
  for (const key of STUDIO_KEYS) {
    const rows = [...page.container.querySelectorAll(`[data-row-key="${key}"]`)];
    expect(rows.length).toBeGreaterThan(0);
    expect(rows.every((row) => card(page!).contains(row))).toBe(true);
  }
  expect(page.container.querySelector(".domain-button")).toBeNull();
  // Terminal theme, then the app theme, each with its own Match System Appearance, then the accent.
  expect([...card(page).querySelectorAll("[data-theme-row]")].map((row) => row.getAttribute("data-theme-row"))).toEqual(
    ["match", "single", "app-match", "app", "accent"],
  );
});

test("every popup is the same fixed-width button, and every row has its Reset slot after the control", async () => {
  page = await renderPage({ path: "/settings/theme" });
  const buttons = [...card(page).querySelectorAll("[data-theme-picker], [data-accent-picker]")];
  expect(buttons.length).toBe(3);
  for (const button of buttons) expect(button.classList.contains("theme-button")).toBe(true);
  for (const row of card(page).querySelectorAll("[data-theme-row]")) {
    expect(row.querySelector(".row-control > :last-child")?.classList.contains("reset-slot")).toBe(true);
  }
  // At the defaults no Reset shows; a changed accent shows its own, in the slot that was there.
  expect(card(page).querySelector(".reset-slot[data-shown]")).toBeNull();
  await run(() => page!.store.set("appearance.accent", "blue"));
  expect(themeRow(page, "accent")!.querySelector(".reset-slot[data-shown]")).not.toBeNull();
});

test("the accent is a swatch popup: each choice has its swatch, the check is on the right, a pick writes it", async () => {
  page = await renderPage({ path: "/settings/theme", mock: { values: { "appearance.theme": "Dracula" } } });
  const button = themeRow(page, "accent")!.querySelector<HTMLElement>("[data-accent-picker]")!;
  expect(button.textContent).toContain(t("settings.choice.accent.neutral"));
  expect(button.querySelector("[data-accent-swatch]")?.getAttribute("style")).toContain("background");
  await click(button);
  const options = [...document.querySelectorAll<HTMLElement>("[data-accent-option]")];
  expect(options.map((option) => option.getAttribute("data-accent-option"))).toEqual([
    "neutral",
    "theme",
    "art",
    "red",
    "green",
    "yellow",
    "blue",
    "magenta",
    "cyan",
  ]);
  for (const option of options) expect(option.querySelector("[data-accent-swatch]")).not.toBeNull();
  // Art Color's hue comes from the art: a wheel, not a color of the theme.
  expect(document.querySelector('[data-accent-option="art"] [data-accent-art]')).not.toBeNull();
  // Red is Dracula's red, made to meet contrast; it differs from Neutral's.
  const swatch = (value: string) =>
    document.querySelector<HTMLElement>(`[data-accent-option="${value}"] [data-accent-swatch]`)!.style.background;
  expect(swatch("red")).not.toBe(swatch("neutral"));
  // Only the chosen row has the check, as its row's last element.
  const checked = options.filter((option) => option.querySelector(".theme-option-check"));
  expect(checked.map((option) => option.getAttribute("data-accent-option"))).toEqual(["neutral"]);
  expect(checked[0]!.querySelector(".theme-option-row > :last-child")?.classList.contains("theme-option-check")).toBe(
    true,
  );
  await fire(document.querySelector('[data-accent-option="blue"]')!, "mousedown");
  expect(ops(page.provider, "cmux.settings.set").at(-1)).toEqual({ key: "appearance.accent", value: "blue" });
  expect(button.textContent).toContain(t("settings.choice.accent.blue"));
});

test("the app theme's Match System Appearance follows the terminal's until the app theme has its own pick", async () => {
  page = await renderPage({ path: "/settings/theme" });
  const appSwitch = () => themeRow(page!, "app-match")!.querySelector<HTMLButtonElement>("[role=switch]")!;
  expect(appSwitch().disabled).toBe(true);
  expect(themeRow(page, "app-match")!.textContent).toContain(t("settingsPage.theme.appFollowsTerminal"));
  await run(() => page!.store.set("appearance.appTheme", "Gruvbox Dark"));
  expect(appSwitch().disabled).toBe(false);
  await click(appSwitch());
  expect(ops(page.provider, "cmux.settings.set").at(-1)).toEqual({
    key: "appearance.appTheme",
    value: expect.stringMatching(/^light:.+,dark:.+$/),
  });
  expect(themeRow(page, "app")).toBeNull();
  expect(themeRow(page, "app-light")).not.toBeNull();
  expect(themeRow(page, "app-dark")).not.toBeNull();
  // A side of the pair is always a theme: its list has no Match Terminal Theme row.
  await click(themeRow(page, "app-light")!.querySelector("[data-theme-picker]")!);
  expect([...document.querySelectorAll(".theme-option")].map((option) => option.textContent)).not.toContain(
    t("settings.default.followTerminal"),
  );
  expect(document.querySelectorAll("[data-theme-option]").length).toBeGreaterThan(0);
});

test("a theme row in search results is the Theme section's picker, not a plain list", async () => {
  page = await renderPage({ path: "/settings/general" });
  await changeValue(page.container.querySelector<HTMLInputElement>("[data-settings-search]")!, "app theme");
  const row = page.container.querySelector<HTMLElement>('[data-search-results] [data-row-key="appearance.appTheme"]')!;
  expect(row.querySelector("[data-theme-picker]")?.textContent).toContain(t("settings.default.followTerminal"));
  expect(row.querySelector(".domain-button")).toBeNull();
  await click(row.querySelector("[data-theme-picker]")!);
  expect(document.querySelector(".theme-popover input")?.getAttribute("placeholder")).toBe(
    t("settingsWindow.themeSearch"),
  );
  expect(document.querySelector(".theme-count")).not.toBeNull();
});

test("?focus= on a theme key reveals its row in the card", async () => {
  page = await renderPage({ path: "/settings/theme?focus=appearance.accent" });
  expect(document.activeElement?.closest('[data-theme-row="accent"]')).not.toBeNull();
});

test("Back to the same ?focus= reveals the row again after a route without it", async () => {
  page = await renderPage({ path: "/settings/theme?focus=appearance.accent" });
  (document.activeElement as HTMLElement | null)?.blur();
  await run(() => page!.history.push("/settings/theme"));
  expect(document.activeElement?.closest('[data-theme-row="accent"]')).toBeNull();
  await run(() => page!.history.push("/settings/theme?focus=appearance.accent"));
  expect(document.activeElement?.closest('[data-theme-row="accent"]')).not.toBeNull();
});

test("search-result theme pickers draw the default choice's colors, not an empty circle", async () => {
  page = await renderPage({ path: "/settings/general" });
  for (const [query, key] of [
    ["terminal theme", "appearance.theme"],
    ["app theme", "appearance.appTheme"],
  ] as const) {
    await changeValue(page.container.querySelector<HTMLInputElement>("[data-settings-search]")!, query);
    const button = page.container.querySelector<HTMLElement>(
      `[data-search-results] [data-row-key="${key}"] [data-theme-picker]`,
    )!;
    expect(button.querySelector(".theme-ball")).not.toBeNull();
    expect(button.querySelector(".theme-ball-empty")).toBeNull();
  }
});

test("a pick on one side of the app pair keeps the other side; Match off goes back to one theme", async () => {
  page = await renderPage({
    path: "/settings/theme",
    mock: { values: { "appearance.appTheme": "light:GitHub Light,dark:Dracula" } },
  });
  await click(themeRow(page, "app-light")!.querySelector("[data-theme-picker]")!);
  await click(document.querySelector('[data-theme-option="Solarized Light"]')!.closest("li")!);
  expect(ops(page.provider, "cmux.settings.set").at(-1)).toEqual({
    key: "appearance.appTheme",
    value: "light:Solarized Light,dark:Dracula",
  });
  await click(themeRow(page, "app-match")!.querySelector("[role=switch]")!);
  expect(ops(page.provider, "cmux.settings.set").at(-1)).toEqual({
    key: "appearance.appTheme",
    value: expect.not.stringContaining(":"),
  });
  expect(themeRow(page, "app")).not.toBeNull();
});

test("a managed app theme pair says why its controls are off", async () => {
  page = await renderPage({
    path: "/settings/theme",
    mock: {
      managed: {
        "appearance.appTheme": {
          value: "light:GitHub Light,dark:Dracula",
          source: "profile",
          reason: "Set by your organization",
        },
      },
    },
  });
  expect(themeRow(page, "app-match")!.querySelector("[data-managed-reason]")).not.toBeNull();
  expect(themeRow(page, "app-match")!.querySelector<HTMLButtonElement>("[role=switch]")!.disabled).toBe(true);
  expect(themeRow(page, "app-light")!.querySelector<HTMLButtonElement>("[data-theme-picker]")!.disabled).toBe(true);
});

test("the Reset command on a focused studio row resets its key", async () => {
  page = await renderPage({ path: "/settings/theme", mock: { values: { "appearance.accent": "blue" } } });
  themeRow(page, "accent")!.querySelector<HTMLElement>("[data-accent-picker]")!.focus();
  await run(() => page!.provider.sendCommand("reset"));
  expect(ops(page.provider, "cmux.settings.reset")).toEqual([{ key: "appearance.accent" }]);
});

test("?focus= on a paired theme lands on its Light row, once: a later Match switch keeps the focus", async () => {
  page = await renderPage({
    path: "/settings/theme?focus=appearance.theme",
    mock: { values: { "appearance.theme": "light:GitHub Light,dark:Dracula" } },
  });
  expect(document.activeElement?.closest('[data-theme-row="light"]')).not.toBeNull();
  const toggle = themeRow(page, "match")!.querySelector<HTMLElement>("[role=switch]")!;
  toggle.focus();
  await click(toggle);
  expect(themeRow(page, "single")).not.toBeNull();
  expect(document.activeElement).toBe(toggle);
});

// The schema's App Theme group was the only place these keys showed a settings-file notice, a
// managed reason or a refused write; the card's rows show them as every SettingRow does.
test("the card's rows show the key's notice, managed reason and refused write", async () => {
  page = await renderPage({
    path: "/settings/theme",
    mock: {
      diagnostics: [{ path: "appearance.theme", message: "theme must be a string" }],
      managed: { "appearance.appTheme": { value: "Dracula", source: "profile", reason: "Set by your organization" } },
    },
  });
  expect(themeRow(page, "match")!.querySelector("[data-notice]")?.textContent).toContain("theme must be a string");
  expect(themeRow(page, "single")!.querySelector("[data-notice]")).toBeNull();
  expect(themeRow(page, "app-match")!.querySelector("[data-managed-reason]")).not.toBeNull();
  expect(themeRow(page, "app-match")!.hasAttribute("data-managed")).toBe(true);
  await run(() => page!.store.set("appearance.accent", "not-an-accent"));
  expect(themeRow(page, "accent")!.querySelector(".row-error")).not.toBeNull();
});
