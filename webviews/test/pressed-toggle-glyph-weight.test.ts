// A toggle shows it is on through its ink and the square behind it, never by drawing its glyph in the
// pack's heavier Solid form (Leo 2026-11-06: "Why is it bolded after I click on it to get it toggled?
// ... the symbol itself is getting bolded for some reason."). The detector: a component that presses a
// button with some state must not hand that same state to an icon's `selected`. A glyph whose on
// form is a different shape (a filled pin) names that in its own prop, not the pressed state.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const SRC = join(import.meta.dir, "../src");

function sources(): string[] {
  const glob = new Bun.Glob("**/*.tsx");
  return [...glob.scanSync(SRC)].filter((file) => !/\.(test|gallery|fixture)\.tsx$/.test(file));
}

test("no pressed toggle draws its glyph heavier when on", () => {
  const offenders: string[] = [];
  for (const file of sources()) {
    const text = readFileSync(join(SRC, file), "utf8");
    const pressed = new Set([...text.matchAll(/aria-pressed=\{([^}]+)\}/g)].map((match) => match[1]!.trim()));
    if (!pressed.size) continue;
    for (const match of text.matchAll(/<(?:Icon|HeaderIcon)\b[^>]*\bselected=\{([^}]+)\}/g)) {
      if (pressed.has(match[1]!.trim())) offenders.push(`${file}: selected={${match[1]}}`);
    }
  }
  expect(offenders).toEqual([]);
});
