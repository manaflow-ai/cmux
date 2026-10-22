// Glass is never opaque: no blurred surface or glass token in webviews/src paints a solid fill
// outside Reduce Transparency (scripts/check-glass-never-opaque.ts says what counts and how a
// reviewed exception is written). The Swift side is the ast-grep rule no-opaque-glass.
import { expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { findOpaqueGlass, findSolidTooltipMarkup } from "../scripts/check-glass-never-opaque";

test("glass is never opaque", () => {
  expect(findOpaqueGlass()).toEqual([]);
});

// Leo 2026-10-21: "WHERE IS THE GLASS EVERYWHERE, all these hover tooltips and hover previews".
test("every tooltip and hover card in the page code is glass", () => {
  expect(findSolidTooltipMarkup()).toEqual([]);
});

// A tooltip or hover card is glass with or without its own blur; `backdrop-filter: none` is no way out.
test("the scan flags a solid tooltip or hover card", () => {
  const dir = mkdtempSync(join(tmpdir(), "glass-never-opaque-tooltip-"));
  try {
    writeFileSync(
      join(dir, "fixture.css"),
      [
        ":root { --x-solid: #123456; --x-glass: color-mix(in srgb, var(--x-solid) 60%, transparent); }",
        ".x-tooltip { background: var(--x-solid); backdrop-filter: none; }",
        ".x-hover-card { background: Canvas; }",
        '[role="tooltip"] { background-color: #fff; }',
        ".ui-card { background: var(--cmux-popup-surface); }",
        ".glass-tooltip { background: var(--x-glass); }",
        ".clear-tooltip { background: transparent; }",
        "@media (prefers-reduced-transparency: reduce) { .rt-tooltip { background: Canvas; } }",
        ".allowed-tooltip { /* glass-opaque-allow: fixture */ background: white; }",
        ".plain-card { background: var(--x-solid); backdrop-filter: none; }",
      ].join("\n"),
    );
    writeFileSync(
      join(dir, "Fixture.tsx"),
      [
        'export const solid = <div className="ui-tooltip">a</div>;',
        'export const card = <div className="ui-tooltip ui-card">b</div>;',
        'export const title = "ui-title-tooltip";',
        'export const glass = <div className="ui-tooltip ui-glass">c</div>;',
        'export const part = <span className="ui-tooltip-hint">d</span>;',
        'export const query = document.querySelector(".ui-title-tooltip");',
      ].join("\n"),
    );
    const selectors = findOpaqueGlass(dir).map((line) => line.split(": ")[1]?.split(" {")[0]);
    expect(selectors).toEqual([".x-tooltip", ".x-hover-card", '[role="tooltip"]', ".ui-card"]);
    expect(findSolidTooltipMarkup(dir).map((line) => line.split(": ")[1])).toEqual([
      '"ui-tooltip"',
      '"ui-tooltip ui-card"',
      '"ui-title-tooltip"',
    ]);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

// The scan is not vacuous: it finds each opaque form and passes the solid surfaces that are not glass.
test("the scan flags opaque glass and only opaque glass", () => {
  const dir = mkdtempSync(join(tmpdir(), "glass-never-opaque-"));
  try {
    writeFileSync(
      join(dir, "fixture.css"),
      [
        ":root { --x-solid: #123456; --x-glass: color-mix(in srgb, var(--x-solid) 60%, transparent); }",
        ".hex { background: #fff; backdrop-filter: blur(4px); }",
        ".mix { background: color-mix(in srgb, var(--x-solid) 30%, white); -webkit-backdrop-filter: blur(2px); }",
        ".token { --card-glass: var(--x-solid); }",
        ".share { --queue-glass: 100%; }",
        ".host { background: var(--cmux-popup-surface); backdrop-filter: blur(1px); }",
        ".named-glass { background: black; }",
        ".tinted { background: rgb(0 0 0 / 40%); backdrop-filter: blur(2px); }",
        ".glassy { background: var(--x-glass); backdrop-filter: blur(1px); }",
        ".solid-card { background: var(--x-solid); backdrop-filter: none; }",
        ".unknown { background: var(--from-the-host); backdrop-filter: blur(1px); }",
        "@media (prefers-reduced-transparency: reduce) { .rt { background: Canvas; backdrop-filter: blur(1px); } }",
        ":root[data-reduce-transparency] .rt { background: Canvas; backdrop-filter: blur(1px); }",
        ":root:not([data-reduce-transparency]) .not-rt { background: Canvas; backdrop-filter: blur(1px); }",
        ".allowed { /* glass-opaque-allow: fixture */ background: white; backdrop-filter: blur(1px); }",
      ].join("\n"),
    );
    const selectors = findOpaqueGlass(dir).map((line) => line.split(": ")[1]?.split(" {")[0]);
    expect(selectors).toEqual([
      ".hex",
      ".mix",
      ".token",
      ".share",
      ".host",
      ".named-glass",
      ":root:not([data-reduce-transparency]) .not-rt",
    ]);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
