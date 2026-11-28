// A chevron's turn or slide takes a motion token, never a literal (docs/cmux-next/ui-guidelines.md; Leo, 2026-11-27:
// "these chevrons are too close dont we have any guidelines for these yet?"). Every stylesheet rule whose
// selector names a chevron or a disclosure mark and that transitions `transform` must time it with
// --cmux-motion-quick, -micro or -standard (or the pane's --agent-motion-* aliases of them), so a chevron
// never runs slower than the 180 ms the guideline allows and a change of the scale reaches all of them.
import { expect, test } from "bun:test";
import { readdirSync, readFileSync } from "node:fs";
import path from "node:path";

const SRC = path.resolve(import.meta.dir, "../src");
const CHEVRON = /chevron|disclosure|caret|summary::(?:before|after)/i;
// The scale's tokens, or a surface's own alias of one (`--cv-fold-duration`, `--pcd-motion`), which this
// file does not chase; --cmux-motion-large and the send pop are refused by name.
const ALLOWED = /var\(--(?:cmux-motion-(?:quick|micro|standard)|[a-z0-9-]*(?:motion|duration)[a-z0-9-]*)\b/;
const REFUSED = /var\(--cmux-motion-(?:large|send|send-pop)\b/;

function cssFiles(dir: string): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) return entry.name === "node_modules" ? [] : cssFiles(full);
    return entry.name.endsWith(".css") ? [full] : [];
  });
}

/** Each `selector { body }` rule of a stylesheet, comments dropped, @-blocks flattened. */
function rules(text: string): { selector: string; body: string; line: number }[] {
  const clean = text.replace(/\/\*[\s\S]*?\*\//g, (comment) => comment.replace(/[^\n]/g, " "));
  const found: { selector: string; body: string; line: number }[] = [];
  const rule = /([^{};]+)\{([^{}]*)\}/g;
  for (let match = rule.exec(clean); match; match = rule.exec(clean))
    found.push({
      selector: match[1]!.trim(),
      body: match[2]!,
      line: clean.slice(0, match.index).split("\n").length,
    });
  return found;
}

/** The chevron rules that time a transform with anything but an allowed token. */
export function chevronMotionFaults(file: string, text: string): string[] {
  const faults: string[] = [];
  for (const { selector, body, line } of rules(text)) {
    if (!CHEVRON.test(selector)) continue;
    for (const declaration of body.split(";")) {
      const [property, ...rest] = declaration.split(":");
      const value = rest.join(":");
      if (!/^\s*transition(?:-duration)?\s*$/.test(property ?? "")) continue;
      for (const part of value.split(/,(?![^(]*\))/)) {
        if (!/transform|all/.test(part) && !/^\s*transition-duration/.test(property!)) continue;
        if (!/\d+m?s\b/.test(part.replace(/var\([^)]*\)/g, "")) && ALLOWED.test(part) && !REFUSED.test(part)) continue;
        if (/^\s*(?:none|0m?s)\s*$/.test(part)) continue;
        faults.push(
          `${path.relative(SRC, file)}:${line} ${selector.split("\n").pop()!.trim()} { ${property!.trim()}:${part.trim()} }`,
        );
      }
    }
  }
  return faults;
}

test("a literal chevron duration is caught", () => {
  expect(chevronMotionFaults("x.css", ".a-chevron { transition: transform 120ms ease; }").length).toBe(1); // motion-allow: the literal the lint must refuse
  expect(
    chevronMotionFaults("x.css", ".a-chevron { transition: transform var(--cmux-motion-large) ease; }").length,
  ).toBe(1);
  expect(
    chevronMotionFaults(
      "x.css",
      ".a-chevron { transition: transform var(--cmux-motion-micro, 120ms) var(--cmux-ease-out); }",
    ),
  ).toEqual([]);
});

test("every chevron's motion takes a token no slower than --cmux-motion-standard", () => {
  const faults = cssFiles(SRC).flatMap((file) => chevronMotionFaults(file, readFileSync(file, "utf8")));
  expect(faults).toEqual([]);
});
