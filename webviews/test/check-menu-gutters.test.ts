// The menu-gutter lint (scripts/check-menu-gutters.ts): a menu check no wider than its glyph's 12
// and a menu row's gap no more than 6, unless the rule says menu-gutter-allow: <reason>.
import { expect, test } from "bun:test";
import { findAllMenuGutters, findMenuGutters } from "../scripts/check-menu-gutters";

test("the webviews have no menu gutter wider than the glyph", () => {
  expect(findAllMenuGutters().map((f) => `${f.file}:${f.line} ${f.selector} { ${f.prop}: ${f.value} }`)).toEqual([]);
});

test("a wide check box and a wide row gap fail; tokens, small values and allowed rules pass", () => {
  const css = `
.x-menu .ui-menu-check { width: 16px; height: 16px; }
.x-menu-item { display: flex; gap: 8px; }
.y-menu-check{width:12px}
.z-menu-item{gap:var(--cmux-menu-icon-gap)}
.w-menu .ui-menu-check {
  /* menu-gutter-allow: a trailing number column by design */
  width: 16px;
}
.unrelated { width: 40px; gap: 20px; }
`;
  expect(findMenuGutters("sample.css", css).map((f) => `${f.line} ${f.prop}: ${f.value}`)).toEqual([
    "2 width: 16px",
    "3 gap: 8px",
  ]);
});
