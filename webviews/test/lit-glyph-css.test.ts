// A lit (pressed, checked, on) control's glyph is never fainter than at rest: its ink is
// `--agent-lit-glyph` / `--cmux-lit-glyph` (ThemeTokens.litGlyph, the accent lifted to the muted
// text's contrast), never the raw accent, which is fainter than the rest ink in every bundled
// theme. The Swift side is the ast-grep rule no-raw-accent-lit-glyph. A fill or wash may still
// mix the accent; only `color` is checked.
import { expect, test } from "bun:test";
import { readdirSync, readFileSync } from "node:fs";
import { join, relative } from "node:path";

const SRC = join(import.meta.dir, "../src");
// A menu row's check (`.ui-menu-check`) draws only on the chosen row, so its ink is lit too.
const LIT =
  /aria-(pressed|checked|selected)=["']?true|\.is-on\b|\[data-on\b|data-state=["']?on\b|:checked\b|\.ui-menu-check\b/;
const RAW_ACCENT_INK = /(?<![\w-])color\s*:\s*var\(\s*--(agent|cmux)-accent\s*[,)]/;

function cssFiles(dir: string): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) return cssFiles(path);
    return entry.name.endsWith(".css") ? [path] : [];
  });
}

test("a lit control's ink is the lit glyph, not the raw accent", () => {
  const found: string[] = [];
  for (const file of cssFiles(SRC)) {
    const css = readFileSync(file, "utf8").replace(/\/\*[\s\S]*?\*\//g, "");
    for (const [, selector = "", body = ""] of css.matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
      if (LIT.test(selector) && RAW_ACCENT_INK.test(body)) {
        found.push(`${relative(SRC, file)}: ${selector.trim().replace(/\s+/g, " ")}`);
      }
    }
  }
  expect(found).toEqual([]);
});
