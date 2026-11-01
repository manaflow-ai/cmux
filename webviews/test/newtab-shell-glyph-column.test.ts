// New Tab's shell mode draws `!` before the command (.nt-input-glyph, absolutely placed at the field's
// start). In Claude's look (the split row) the text starts one lead gap after +, and `!` stands in that
// gap; in Codex's look (no split) there is no gap, so the field keeps the reserved glyph column and
// `!pwd` never draws `!` over the `p`. jsdom computes no layout, so this pins newtab/screen.css.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const css = readFileSync(join(import.meta.dir, "../src/agent-session/acpmux/newtab/screen.css"), "utf8");

function selectorsPadding(prop: RegExp): string[] {
  return [...css.matchAll(/([^{}]+)\{([^}]*)\}/g)]
    .filter((m) => prop.test(m[2]))
    .flatMap((m) => m[1].split(",").map((s) => s.trim()));
}

test("Codex's look (no split) reserves the shell glyph's column", () => {
  // The inset is the field's own variable (#29659), so the placeholder starts where the text does.
  const reserved = selectorsPadding(
    /--nt-field-pad-inline-start:\s*var\(--ds-control-icon\)[^}]*padding-inline-start:\s*var\(--nt-field-pad-inline-start\)/,
  );
  expect(reserved).toContain(".nt-input:not([data-split]) .nt-field-slot .nt-field");
});

test("Claude's look (split) moves the glyph into the lead gap instead", () => {
  expect(css).toMatch(
    /\.nt-input\[data-split\] \.nt-field-slot:not\(\[data-glyph-column\]\) \.nt-input-glyph \{[^}]*inset-inline-start:\s*calc\(-1 \* var\(--acpmux-composer-lead-gap\)\)/,
  );
});
