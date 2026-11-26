// Glass Controls (appearance.glassControls, Taste Board #164): off by default, the page draws
// today's switches and sliders; on, the `.settings` root carries `data-glass-controls` and every
// rule of glassControls.css is scoped to it, so nothing changes until the setting is on.
import { afterAll, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { act } from "react";
import { GLASS_CONTROLS_KEY } from "./glassControls";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle } = await import("./testing");

const root = (container: HTMLElement) => container.querySelector<HTMLElement>(".settings")!;

test("off by default: the page root carries no glass attribute", async () => {
  const page = await renderPage({ path: "/settings/appearance" });
  expect(root(page.container)).not.toBeNull();
  expect(root(page.container).hasAttribute("data-glass-controls")).toBe(false);
  page.unmount();
});

test("only an explicit true turns it on", async () => {
  for (const value of ["true", 1, null]) {
    const page = await renderPage({
      path: "/settings/appearance",
      mock: { values: { [GLASS_CONTROLS_KEY]: value } },
    });
    expect(root(page.container).hasAttribute("data-glass-controls")).toBe(false);
    page.unmount();
  }
});

test("on, the root carries the attribute, and turning it off removes it live", async () => {
  const page = await renderPage({
    path: "/settings/appearance",
    mock: { values: { [GLASS_CONTROLS_KEY]: true } },
  });
  expect(root(page.container).getAttribute("data-glass-controls")).toBe("");
  // The switches and sliders the sheet draws are inside that root.
  expect(root(page.container).querySelector(".ui-switch")).not.toBeNull();
  await act(async () => void (await page.store.set(GLASS_CONTROLS_KEY, false)));
  await settle();
  expect(root(page.container).hasAttribute("data-glass-controls")).toBe(false);
  page.unmount();
});

test("every rule of the sheet is scoped to the opt-in, and the press grows only with motion allowed", () => {
  const sheet = readFileSync(new URL("./glassControls.css", import.meta.url), "utf8").replace(/\/\*[\s\S]*?\*\//g, "");
  const selectors = [...sheet.matchAll(/([^{}]+)\{/g)]
    .map((match) => match[1]!.trim())
    .filter((selector) => selector !== "" && !selector.startsWith("@media"));
  expect(selectors.length).toBeGreaterThan(4);
  for (const group of selectors)
    for (const selector of group.split(/,(?![^(]*\))/)) expect(selector).toContain(".settings[data-glass-controls]");
  // The grow (scale) lives only inside the no-preference media block, and never under cmux's own
  // reduced or off motion.
  const growBlock = sheet.slice(sheet.indexOf("@media (prefers-reduced-motion: no-preference)"));
  const beforeGrow = sheet.slice(0, sheet.indexOf("@media (prefers-reduced-motion: no-preference)"));
  expect(beforeGrow).not.toMatch(/scale\s*[:(]\s*var\(--glass-knob-grow\)/);
  expect(growBlock).toContain('[data-cmux-motion="reduced"]');
  // The page loads the sheet through page.css, after the look it overrides.
  const page = readFileSync(new URL("./page.css", import.meta.url), "utf8");
  expect(page.indexOf('@import "./glassControls.css"')).toBeGreaterThan(page.indexOf('@import "./look.css"'));
});
