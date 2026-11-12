// l10n-allow-file: test diagnostics.
// Hover-revealed controls never stay shown by `:focus-within`. A page in the app keeps DOM focus
// when another pane or app takes the keyboard (src/agent-session/acpmux/pageKey.ts), and a click
// leaves focus on what it pressed, so a reveal held by `:focus-within` stays drawn after the person
// has gone elsewhere (Leo, 2026-11-12, on a queued prompt's Steer, trash and ⋯: "if i click into
// the app or click into you for the workspace like focus anything the composer just the window the
// pane it should fade away"). The keyboard's reach is `:has(:focus-visible)` instead: the build
// gates every `:focus-visible` on a key having earned it (FOCUS-RING, src/ui/focusModality.ts), and
// the window's blur, a press or a scroll takes it away.
//
// Detector: every style rule whose selector holds `:focus-within` and whose block sets `opacity: 1`
// or `visibility: visible` is listed; ALLOWED names the ones that reveal on purpose, with why.
import { expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import path from "node:path";

const webviews = path.resolve(import.meta.dir, "..");

/** Rules that show a control on focus by design, and why a stale focus there is right. */
const ALLOWED: Record<string, string> = {
  // A chief card is picked by focusing it (a click or a key); its actions are the picked card's.
  ".acpmux-chief-card:focus-within .acpmux-chief-card-actions": "the focused card is the picked one",
  ".acpmux-chief-card:focus-within .acpmux-chief-card-dismiss": "the focused card is the picked one",
};

/// Each selector that reveals by `:focus-within`, from the innermost blocks of `css`.
export function focusWithinReveals(css: string): string[] {
  const source = css.replace(/\/\*[\s\S]*?\*\//g, "");
  const found: string[] = [];
  for (const [, prelude, body] of source.matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
    if (!/opacity\s*:\s*1(?![\d.])|visibility\s*:\s*visible/.test(body!)) continue;
    for (const selector of prelude!.split(",").map((part) => part.trim().replace(/\s+/g, " ")))
      if (selector.includes(":focus-within")) found.push(selector);
  }
  return found;
}

test("the scanner finds a reveal held by :focus-within and leaves the keyboard's form alone", () => {
  expect(focusWithinReveals(".row:is(:hover, :focus-within) .act { opacity: 1; }")).toEqual([
    ".row:is(:hover, :focus-within) .act",
  ]);
  expect(focusWithinReveals(".row:focus-within .pr { visibility: visible; }")).toEqual([".row:focus-within .pr"]);
  expect(focusWithinReveals(".row:is(:hover, :has(:focus-visible)) .act { opacity: 1; }")).toEqual([]);
  // A focus rim or a partial fade is no reveal.
  expect(focusWithinReveals(".box:focus-within { border-color: red; opacity: 0.6; }")).toEqual([]);
  expect(focusWithinReveals("/* .a:focus-within { opacity: 1 } */")).toEqual([]);
});

test("no webview stylesheet keeps a hover-revealed control shown by :focus-within", () => {
  const files = execFileSync("git", ["ls-files", "src/**/*.css", "src/*.css"], { cwd: webviews, encoding: "utf8" })
    .split("\n")
    .filter((file) => file && !file.includes(".gallery."));
  expect(files).toContain("src/agent-session/acpmux/styles.css");
  const found = files.flatMap((file) =>
    focusWithinReveals(readFileSync(path.join(webviews, file), "utf8"))
      .filter((selector) => !(selector in ALLOWED))
      .map((selector) => `${file}: ${selector}`),
  );
  expect(found).toEqual([]);
});
