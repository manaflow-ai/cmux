// A theme's own accent (cx-wqn5.1): `<theme>/accent` in appearance.themeEdits is an editor swatch
// like the palette's, and the preview's app accent derives from it; a theme file's
// `# cmux-accent` line is the theme's accent before any edit.
import { afterAll, afterEach, expect, test } from "bun:test";
import { deriveAppTheme } from "../../theme/appTheme";
import { parseGhosttyTheme } from "../../theme/ghosttyTheme";
import { mockThemeColors } from "./mockThemes";
import { installDom } from "./testDom";
import type { Rendered } from "./testing";

const restore = installDom();
afterAll(() => restore());
const { renderPage } = await import("./testing");

let page: Rendered | null = null;
afterEach(() => {
  page?.unmount();
  page = null;
});

const dracula = mockThemeColors.find((theme) => theme.name === "Dracula")!;
const fills = (page: Rendered) =>
  [...page.container.querySelectorAll("[data-theme-preview] [fill]")].map((node) => node.getAttribute("fill"));

test("an accent edit is the theme's swatch and its preview's accent", async () => {
  page = await renderPage({
    path: "/settings/theme",
    mock: { values: { "appearance.theme": "Dracula", "appearance.themeEdits": { "Dracula/accent": "#FF5555" } } },
  });
  const swatch = page.container.querySelector<HTMLElement>('[data-token="accent"]')!;
  expect(swatch.getAttribute("aria-label")).toContain("#ff5555");
  expect(swatch.hasAttribute("data-edited")).toBe(true);
  const edited = deriveAppTheme({ ...dracula, accent: "#ff5555" }).tokens.accent;
  expect(edited).not.toBe(deriveAppTheme(dracula).tokens.accent);
  expect(fills(page)).toContain(edited);
});

test("without an edit the swatch shows the accent the app derives, and a file's cmux-accent is the theme's", async () => {
  page = await renderPage({ path: "/settings/theme", mock: { values: { "appearance.theme": "Dracula" } } });
  const swatch = page.container.querySelector<HTMLElement>('[data-token="accent"]')!;
  expect(swatch.getAttribute("aria-label")).toContain(deriveAppTheme(dracula).tokens.accent);
  expect(swatch.hasAttribute("data-edited")).toBe(false);

  const saved = parseGhosttyTheme(
    "Mine",
    "# Mine: saved by cmux\nbackground = #101010\nforeground = #eeeeee\n# cmux-accent = #EB6F92\n",
  );
  expect(saved?.accent).toBe("#eb6f92");
  expect(
    parseGhosttyTheme("Plain", "background = #101010\nforeground = #eeeeee\n# accent = #eb6f92\n")?.accent,
  ).toBeUndefined();
});
