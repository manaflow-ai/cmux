// l10n-allow-file: layout fixtures, not shipped UI.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { renderToStaticMarkup } from "react-dom/server";
import { createElement } from "react";
import { Window } from "happy-dom";
import { DensityPreview } from "../src/pages/settings/components/DensityCard";
import { PRESETS } from "../src/pages/settings/density";

const pageCSS = [
  "pages/shared/desktop.css",
  "pages/shared/pageBase.css",
  "ui/controls.css",
  "ui/popupSurface.css",
  "pages/settings/styles.css",
  "pages/settings/layout.css",
  "pages/settings/refined.css",
  "pages/settings/look.css",
  "pages/shared/pageDensity.css",
]
  .map((name) => readFileSync(new URL(`../src/${name}`, import.meta.url), "utf8").replace(/^@import .*$/gm, ""))
  .join("\n");

function fixture(markup: string, scale: number, text = scale) {
  const win = new Window();
  win.document.documentElement.dataset.settingsLook = "refined";
  win.document.documentElement.style.setProperty("--cmux-density-scale", String(scale));
  win.document.documentElement.style.setProperty("--cmux-density-text-scale", String(text));
  win.document.head.innerHTML = `<style>${pageCSS}</style>`;
  win.document.body.innerHTML = markup;
  const style = (selector: string) => win.getComputedStyle(win.document.querySelector(selector)!);
  return { win, style };
}

// Happy DOM resolves variables but leaves calc arithmetic in computed styles.
function pixels(value: string) {
  const tokens = value
    .replaceAll("calc", "")
    .replaceAll("px", "")
    .match(/[\d.]+|[()+*/-]/g)!;
  let index = 0;
  const precedence: Record<string, number> = { "+": 1, "-": 1, "*": 2, "/": 2 };
  function expression(minimum = 0): number {
    const token = tokens[index++];
    let result = token === "(" ? expression() : Number(token);
    if (token === "(") expect(tokens[index++]).toBe(")");
    while (index < tokens.length && (precedence[tokens[index]!] ?? -1) >= minimum) {
      const operator = tokens[index++]!;
      const right = expression(precedence[operator]! + 1);
      if (operator === "+") result += right;
      else if (operator === "-") result -= right;
      else if (operator === "*") result *= right;
      else result /= right;
    }
    return result;
  }
  const result = expression();
  expect(index).toBe(tokens.length);
  expect(Number.isFinite(result)).toBe(true);
  return result;
}

for (const scale of [0.8, 1.2]) {
  for (const open of [false, true]) {
    test(`settings disclosure content shares its fill center at ${scale}, open=${open}`, async () => {
      const { win, style } = fixture(
        `<div class="settings"><div class="rows"><button class="more-options" ${open ? "data-open" : ""}><span class="more-options-label">More Options</span><span class="more-options-count">3</span><svg class="more-options-chevron"></svg></button></div></div>`,
        scale,
      );
      try {
        const row = style(".more-options");
        const top = pixels(row.getPropertyValue("--more-options-inset-top"));
        const bottom = pixels(row.getPropertyValue("--more-options-inset-bottom"));
        const paddingTop = pixels(row.paddingTop);
        const paddingBottom = pixels(row.paddingBottom);
        const contentHeight = pixels(style(".more-options-chevron").height);
        const height = Math.max(pixels(row.minHeight), contentHeight + paddingTop + paddingBottom);
        const contentCenter = paddingTop + (height - paddingTop - paddingBottom) / 2;
        const fillCenter = top + (height - top - bottom) / 2;
        expect(row.display).toBe("flex");
        expect(row.alignItems).toBe("center");
        expect(contentCenter).toBeCloseTo(fillCenter, 8);
      } finally {
        await win.happyDOM.abort();
      }
    });
  }
}

for (const scale of [0.8, 28 / 30, 1, 32 / 30, 1.2]) {
  test(`settings scales controls, spacing, icons and corners at ${scale}`, async () => {
    const { win, style } = fixture(
      '<div class="settings"><main class="content"><div class="rows"><div class="row"><span class="row-title">Label</span><button class="ui-button ui-btn" data-icon><svg></svg></button></div></div></main></div><div class="ui-popup"><div class="ui-menu-item"></div></div>',
      scale,
    );
    try {
      expect(pixels(style(".row").paddingTop)).toBeCloseTo(12 * scale);
      expect(pixels(style(".rows").borderRadius)).toBeCloseTo(16 * scale);
      expect(pixels(style(".ui-btn").height)).toBeCloseTo(28 * scale);
      expect(pixels(style(".ui-btn").width)).toBeCloseTo(28 * scale);
      expect(pixels(style(".ui-btn").borderRadius)).toBeCloseTo(8 * scale);
      expect(pixels(style("svg").width)).toBeCloseTo(16 * scale);
      expect(pixels(style(".row-title").fontSize)).toBeCloseTo(13 * scale);
      expect(pixels(style(".ui-menu-item").minHeight)).toBeCloseTo(28 * scale);
      expect(pixels(style(".ui-menu-item").paddingRight)).toBeCloseTo(8 * scale);
      expect(pixels(style(".ui-btn").borderRadius)).toBeLessThan(pixels(style(".ui-btn").width) / 2);
    } finally {
      await win.happyDOM.abort();
    }
  });
}

test("default keeps the host button corner", async () => {
  const { win, style } = fixture('<div class="settings"><button class="ui-button ui-btn"></button></div>', 1);
  try {
    win.document.documentElement.style.setProperty("--cmux-button-radius", "9px");
    expect(pixels(style(".ui-btn").borderRadius)).toBe(9);
  } finally {
    await win.happyDOM.abort();
  }
});

test("density previews scale their example rows with the settings page", async () => {
  const preview = renderToStaticMarkup(createElement(DensityPreview, { density: PRESETS[0]! }));
  const { win, style } = fixture(`<div class="settings">${preview}</div>`, 0.8);
  try {
    expect(pixels(style(".density-item").height)).toBeCloseTo(24 * 0.8);
    expect(pixels(style(".density-item").fontSize)).toBeCloseTo(11.2 * 0.8);
  } finally {
    await win.happyDOM.abort();
  }
});

test("the Chief retains shared sizes when density changes", async () => {
  const { win, style } = fixture(
    '<div class="chief-page"><button class="ui-button ui-btn" data-icon><svg></svg></button></div>',
    1,
  );
  try {
    const metrics = () => [
      style(".ui-btn").width,
      style(".ui-btn").height,
      style("svg").width,
      style(".ui-btn").fontSize,
    ];
    const before = metrics();
    win.document.documentElement.style.setProperty("--cmux-density-scale", "0.8");
    win.document.documentElement.style.setProperty("--cmux-density-text-scale", "0.7");
    expect(metrics()).toEqual(before);
    expect(style(".chief-page").getPropertyValue("--page-density")).toBe("");
  } finally {
    await win.happyDOM.abort();
  }
});
