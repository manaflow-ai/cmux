import { afterAll, afterEach, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { installDom } from "./testDom";
import type { Rendered } from "./testing";

const restore = installDom();
afterAll(restore);
const { renderPage, run } = await import("./testing");
let page: Rendered | null = null;
afterEach(() => {
  page?.unmount();
  page = null;
  document.documentElement.removeAttribute("data-settings-look");
  history.replaceState(null, "", "/");
});

const preview = () => page!.container.querySelector("[data-theme-preview]")!;
const normalized = () => preview().outerHTML.replace(/theme-preview-app-[^" )]+/g, "theme-preview-app-ID");
// Captured from origin/feat-cmux-next at 4081b771ee4; only React clip IDs are normalized.
const original = readFileSync(new URL("./themePreview.default.svg.snap", import.meta.url), "utf8").trim();

test("off preserves the complete upstream theme preview", async () => {
  page = await renderPage({ path: "/settings/theme" });
  expect(document.documentElement.hasAttribute("data-settings-look")).toBe(false);
  expect(normalized()).toBe(original);
});

test("the attribute switches the illustration live and restores the original preview", async () => {
  page = await renderPage({ path: "/settings/theme" });
  await run(() => document.documentElement.setAttribute("data-settings-look", "refined"));
  const app = preview().querySelector('g[aria-hidden="true"]');
  expect(app).not.toBeNull();
  expect(app!.querySelectorAll("text").length).toBe(0);
  expect(normalized()).not.toBe(original);
  await run(() => document.documentElement.removeAttribute("data-settings-look"));
  expect(normalized()).toBe(original);
});

test("host changes toggle the same document without remounting Settings", async () => {
  page = await renderPage({ path: "/settings/theme" });
  const root = page.container.querySelector(".settings");
  for (const on of [true, false, true, false]) {
    await run(() => page!.provider.setHost({ ...page!.provider.host, settings_refined_look: on }));
    expect(document.documentElement.getAttribute("data-settings-look")).toBe(on ? "refined" : null);
    expect(page.container.querySelector(".settings")).toBe(root);
    if (!on) expect(normalized()).toBe(original);
  }
});

test("the browser query enables the same look", async () => {
  history.replaceState(null, "", "/?look=refined");
  page = await renderPage({ path: "/settings/theme" });
  expect(document.documentElement.getAttribute("data-settings-look")).toBe("refined");
  expect(preview().querySelector('g[aria-hidden="true"]')).not.toBeNull();
});

test("mount keeps the shipped look", async () => {
  const { mountSettingsPage } = await import("./mount");
  const { createMockClient } = await import("./mockProvider");
  const mock = createMockClient();
  const root = document.createElement("div");
  document.body.append(root);
  let unmount: (() => void) | undefined;
  try {
    await run(async () => {
      unmount = await mountSettingsPage(root, mock.client);
    });
    expect(document.documentElement.getAttribute("data-settings-look")).toBe("quiet");
  } finally {
    await run(() => unmount?.());
    root.remove();
    mock.close();
  }
});

test("turning the switch off restores the look the page had", async () => {
  document.documentElement.setAttribute("data-settings-look", "quiet");
  page = await renderPage({ path: "/settings/theme" });
  for (const on of [true, false]) {
    await run(() => page!.provider.setHost({ ...page!.provider.host, settings_refined_look: on }));
    expect(document.documentElement.getAttribute("data-settings-look")).toBe(on ? "refined" : "quiet");
  }
  expect(normalized()).toBe(original);
});

test("the variant stylesheet has no matching rules while off", async () => {
  page = await renderPage({ path: "/settings/theme" });
  const css = readFileSync(new URL("./refined.css", import.meta.url), "utf8");
  const style = document.createElement("style");
  style.textContent = css;
  document.head.append(style);
  try {
    const selectors: string[] = [];
    const collect = (rules: CSSRuleList) => {
      for (const rule of rules) {
        if ("selectorText" in rule) selectors.push((rule as CSSStyleRule).selectorText);
        if ("cssRules" in rule) collect((rule as CSSGroupingRule).cssRules);
      }
    };
    collect(style.sheet!.cssRules);
    expect(selectors.length).toBeGreaterThan(30);
    for (const selector of selectors) expect(document.querySelectorAll(selector).length).toBe(0);
    await run(() => document.documentElement.setAttribute("data-settings-look", "refined"));
    expect(selectors.some((selector) => document.querySelector(selector))).toBe(true);
  } finally {
    style.remove();
  }
});
