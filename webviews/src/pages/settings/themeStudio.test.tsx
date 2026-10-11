// The Theme section (P3, P4): the preview draws the theme in effect, the picker writes
// appearance.theme, Match System Appearance writes a light/dark pair, a narrower scope's theme
// shows inline with a Reset that clears that level, and the app theme is the host's `app` level.
import { afterAll, afterEach, expect, test } from "bun:test";
import { installDom } from "./testDom";
import type { Rendered } from "./testing";

const restore = installDom();
afterAll(() => restore());
const { click, fire, ops, renderPage, run } = await import("./testing");

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

test("a theme shows as a round ball: its background, its text color and its six hues, the accent hue largest", async () => {
  page = await renderPage({ path: "/settings/theme", mock: { values: { "appearance.theme": "Dracula" } } });
  const ball = theme(page).querySelector<SVGElement>("[data-theme-picker] [data-theme-ball]")!;
  expect(ball.getAttribute("data-theme-ball")).toBe("Dracula");
  // Only circles: no rounded rectangles or pills.
  expect(ball.querySelectorAll("rect, path, ellipse").length).toBe(0);
  const fill = (selector: string) => ball.querySelector(selector)?.getAttribute("fill");
  expect(fill('[data-ball="surface"]')).toBe("#282a36");
  expect(fill('[data-ball="text"]')).toBe("#f8f8f2");
  const dracula = [
    ["#ff5555", "#ff6e6e"],
    ["#50fa7b", "#69ff94"],
    ["#f1fa8c", "#ffffa5"],
    ["#bd93f9", "#d6acff"],
    ["#ff79c6", "#ff92df"],
    ["#8be9fd", "#a4ffff"],
  ];
  const ring = [...ball.querySelectorAll("[data-ball-hue]")];
  expect(ring.map((dot) => dot.getAttribute("data-ball-hue"))).toEqual(["1", "2", "3", "4", "5", "6"]);
  ring.forEach((dot, index) => expect(dracula[index]).toContain(dot.getAttribute("fill")!));
  // Dracula's `theme` accent is its magenta: that dot is the largest of the ring.
  const accent = ball.querySelector("[data-ball-accent]")!;
  expect(accent.getAttribute("data-ball-hue")).toBe("5");
  const radius = (dot: Element) => Number(dot.getAttribute("r"));
  for (const dot of ring) if (dot !== accent) expect(radius(accent)).toBeGreaterThan(radius(dot));
});

test("a theme previews live in the app before it is picked: hover or arrows, right-click pins it, Escape reverts", async () => {
  page = await renderPage({ path: "/settings/theme" });
  await click(theme(page).querySelector('[data-theme-row="app"] [data-theme-picker]')!);
  const option = (name: string) => document.querySelector<HTMLElement>(`[data-theme-option="${name}"]`)!;
  const previews = () => ops(page!.provider, "cmux.settings.preview");
  // Right-click a theme: the app shows it, without a write, and it stays while the pointer moves on.
  await fire(option("Dracula"), "contextmenu");
  expect(previews().at(-1)).toEqual({ key: "appearance.appTheme", value: "Dracula" });
  expect(option("Dracula").closest("[data-previewing]")).not.toBeNull();
  expect(ops(page.provider, "cmux.settings.set")).toEqual([]);
  // Escape reverts: the preview ends and nothing was written.
  await fire(document.querySelector<HTMLElement>(".theme-search")!, "keydown", { key: "Escape" });
  expect(ops(page.provider, "cmux.settings.preview.end").length).toBeGreaterThan(0);
  expect(ops(page.provider, "cmux.settings.set")).toEqual([]);
});

test("a theme with color edits reads as custom and previews its edited colors", async () => {
  page = await renderPage({
    path: "/settings/theme",
    mock: {
      values: {
        "appearance.theme": "Dracula",
        "appearance.themeEdits": { "Dracula/background": "#101010", "Gruvbox Dark/4": "#123456" },
      },
    },
  });
  expect(theme(page).querySelector("[data-theme-picker]")?.textContent).toContain("Dracula (custom)");
  // The preview draws the edited background; the theme's other colors stay its own.
  expect(theme(page).querySelector("[data-theme-preview] rect")?.getAttribute("fill")).toBe("#101010");
  await click(theme(page).querySelector("[data-theme-picker]")!);
  const name = (theme: string) =>
    document.querySelector(`[data-theme-option="${theme}"] .theme-option-name`)?.textContent ?? "";
  expect(name("Gruvbox Dark")).toBe("Gruvbox Dark (custom)");
  expect(name("Tokyo Night")).toBe("Tokyo Night");
  // The edits never become a setting row of their own.
  expect(page.container.querySelector('[data-row-key="appearance.themeEdits"]')).toBeNull();
});
