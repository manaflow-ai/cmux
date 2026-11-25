// The find pill over a see-through window in Chromium. Chromium draws a backdrop-filter's blurred
// copy over the page's own pixels (ui/glass/glass.css, CHROMIUM OVER THE WINDOW GLASS), so the
// transcript under the chat's Find bar read crisp through its tint: "View changes" and a file list
// under "1 of 2" and the typed query (fleet capture of d65e0292, text-inputs-glass/states.py,
// chat-find art light and dark). Floating glass there lays its tint over the theme surface at
// --glass-underlay; the pill is not a .ui-glass, so it takes the same underlay itself.
import { expect, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";

const css = fs
  .readFileSync(path.resolve(import.meta.dir, "../src/ui/findPill.css"), "utf8")
  .replace(/\/\*[\s\S]*?\*\//g, "");

/** The body of the `.find-pill` rule inside Chromium's `@supports not (-webkit-backdrop-filter: none)`
 * block on a see-through root, or null. */
function chromiumSeeThroughPill(): string | null {
  const block = css.indexOf("@supports not (-webkit-backdrop-filter: none)");
  if (block < 0) return null;
  const rule = /:root\[data-cmux-see-through\][^{]*\.find-pill\s*\{([^}]*)\}/.exec(css.slice(block));
  return rule ? rule[1] : null;
}

test("over a see-through window in Chromium the find pill lays its tint over the glass underlay", () => {
  const body = chromiumSeeThroughPill();
  expect(body).not.toBeNull();
  expect(body!).toMatch(/background\s*:[^;]*var\(--glass-underlay/);
  // The tint stays on top, so the pill's ink keeps its contrast.
  expect(body!).toMatch(/linear-gradient\(\s*var\(--tooltip-tint/);
});

test("the lens, Reduce Transparency and an opaque window keep the tint alone", () => {
  const block = css.slice(css.indexOf("@supports not (-webkit-backdrop-filter: none)"));
  const selector = /(:root\[data-cmux-see-through\][^{]*)\.find-pill\s*\{/.exec(block)?.[1] ?? "";
  expect(selector).toContain("data-glass-lens");
  expect(selector).toContain("data-reduce-transparency");
});
