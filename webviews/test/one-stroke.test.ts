// One stroke from the theme (rule R6 of one material per surface, design/glass-system.md). Leo, 2026-11-21,
// on the tab hover preview: "like this hover preview of the tabs situation has a black border... no bueno.
// no cohesiveness/theme synchronizing! bad." scripts/check-one-stroke.ts says what counts.
import { expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { EDGE_ALLOWED_MAX, edgeFindings, findHardEdges, floatingRule, withoutVars } from "../scripts/check-one-stroke";

test("no floating surface in the page code draws a hard-coded or doubled edge", () => {
  const { errors, allowed } = findHardEdges();
  expect(errors).toEqual([]);
  expect(allowed.length).toBe(EDGE_ALLOWED_MAX);
});

test("a black border on a preview fails", () => {
  const found = edgeFindings(".x-preview { border: 1px solid #000; }", "x.css");
  expect(found).toHaveLength(1);
  expect(found[0]).toContain("[hard-edge]");
});

test("a literal ring on a popup fails", () => {
  const found = edgeFindings(".ui-popup { box-shadow: 0 0 0 1px rgba(0,0,0,.5), 0 8px 24px rgba(0,0,0,.3); }", "x.css");
  expect(found).toHaveLength(1);
  expect(found[0]).toContain("box-shadow ring 0 0 0 1px rgba(0,0,0,.5)");
});

test("a white outline and a black hairline on a hover card fail", () => {
  expect(edgeFindings(".tab-hover-card { outline: 1px solid white; }", "x.css")).toHaveLength(1);
  expect(edgeFindings(".link-hover-card {\n  box-shadow:\n    inset 0 1px 0 #fff;\n}", "x.css")).toHaveLength(1);
});

test("a border and an inset ring on one surface fail as doubled, even in theme tokens", () => {
  const found = edgeFindings(
    ".x-tooltip { border: 1px solid var(--glass-edge); box-shadow: inset 0 0 0 0.5px var(--glass-edge); }",
    "x.css",
  );
  expect(found).toHaveLength(1);
  expect(found[0]).toContain("[doubled]");
});

test("the theme's edge tokens pass", () => {
  expect(edgeFindings(".x-preview { border: 1px solid var(--glass-edge); }", "x.css")).toEqual([]);
  expect(
    edgeFindings(".ui-popup { box-shadow: inset 0 0 0 var(--cmux-hairline, 0.5px) var(--ui-popup-edge); }", "x.css"),
  ).toEqual([]);
  expect(
    edgeFindings(
      ".x-card.ui-glass { border: 1px solid color-mix(in srgb, var(--cmux-text) 14%, transparent); }",
      "x.css",
    ),
  ).toEqual([]);
  // A token's fallback is the token's.
  expect(edgeFindings(".x-toast { border: 1px solid var(--cmux-card-rim, #fff); }", "x.css")).toEqual([]);
});

test("a drop shadow, a part inside a surface, an in-flow card and forced colors pass", () => {
  expect(edgeFindings(".ui-popup { box-shadow: 0 2px 6px rgba(0,0,0,.11); }", "x.css")).toEqual([]);
  expect(edgeFindings(".ui-popup .row { border-bottom: 1px solid #000; }", "x.css")).toEqual([]);
  expect(edgeFindings(".x-menu__item { border: 1px solid #000; }", "x.css")).toEqual([]);
  expect(edgeFindings(".feed-card { border: 1px solid #000; }", "x.css")).toEqual([]);
  expect(edgeFindings("@media (forced-colors: active) { .ui-popup { border: 1px solid white; } }", "x.css")).toEqual(
    [],
  );
});

test("a hard edge with a reason is allowed, and counted against the pin", () => {
  const css = "/* one-material-allow: a test */\n.x-preview { border: 1px solid #000; }";
  expect(edgeFindings(css, "x.css")).toEqual([]);
  const root = mkdtempSync(join(tmpdir(), "one-stroke-"));
  try {
    mkdirSync(join(root, "ui"));
    writeFileSync(join(root, "ui/x.css"), css);
    const result = findHardEdges(root);
    expect(result.allowed).toEqual(["ui/x.css:2: .x-preview"]);
    if (EDGE_ALLOWED_MAX === 0) expect(result.errors.join("\n")).toContain("more than EDGE_ALLOWED_MAX");
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("the floating scope reads a selector's subject only", () => {
  expect(floatingRule({ selector: ".ui-popup" })).toBe(true);
  expect(floatingRule({ selector: ".acpmux-minimap__card" })).toBe(true);
  expect(floatingRule({ selector: ".x-popover--open" })).toBe(true);
  expect(floatingRule({ selector: ".ui-popup > .ui-popup__row" })).toBe(false);
  expect(floatingRule({ selector: ".a, .b .tab-preview:hover" })).toBe(true);
  expect(withoutVars("1px solid var(--a, var(--b, #fff))")).not.toContain("#fff");
});
