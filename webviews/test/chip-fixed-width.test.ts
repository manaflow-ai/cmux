// l10n-allow-file: test names, not shipped UI.
// A chip, tab or card in the agent pane that cuts its text off with an ellipsis uses the room its
// row has: it truncates only when the row is full, never at a fixed width while the row has space
// (Leo 2026-10-20, the pull request bar above the composer cutting "the label is the …" at 360px).
// This reads the pane's stylesheets: a rule with `text-overflow: ellipsis` may not cap its
// `max-width` at a length (px, ch, em, rem); a percentage or `none` follows the row.
import { readFileSync, readdirSync } from "node:fs";
import path from "node:path";
import { expect, test } from "bun:test";

const ROOT = path.resolve(import.meta.dir, "../src/agent-session/acpmux");
/** Design prototypes and gallery pages are not the app's pane. */
const SKIP = /(^|\/)prototype\/|\.gallery\.css$/;

function sheets(dir: string): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) return sheets(full);
    return entry.name.endsWith(".css") ? [full] : [];
  });
}

/** `selector => max-width` for each ellipsized rule capped at a fixed length. */
function fixedCaps(): string[] {
  return sheets(ROOT)
    .filter((file) => !SKIP.test(path.relative(ROOT, file)))
    .flatMap((file) => {
      const css = readFileSync(file, "utf8").replace(/\/\*[\s\S]*?\*\//g, "");
      return [...css.matchAll(/([^{}]+)\{([^{}]*)\}/g)].flatMap(([, selector, body]) => {
        const cap = /max-width\s*:\s*([^;]+)/.exec(body!)?.[1]?.trim();
        if (!cap || !/ellipsis/.test(body!) || !/\d(px|ch|r?em)\b/.test(cap)) return [];
        return [`${path.relative(ROOT, file)} ${selector!.trim().replace(/\s+/g, " ")} => ${cap}`];
      });
    });
}

test("no ellipsized chip, tab or card in the agent pane truncates at a fixed width", () => {
  expect(fixedCaps()).toEqual([]);
});
