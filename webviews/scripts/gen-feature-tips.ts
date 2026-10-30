// Writes src/ui/featureTips/tips.generated.json from the highlights' `tip:` lines
// (src/ui/featureTips/catalog.ts). `--check` exits 1 when the file is stale.
//   bun scripts/gen-feature-tips.ts [--check]
import { readdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { tipsFromHighlights } from "../src/ui/featureTips/catalog";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
export const HIGHLIGHTS = join(ROOT, "release-notes/next/highlights");
export const GENERATED = join(ROOT, "webviews/src/ui/featureTips/tips.generated.json");

export function generatedTips(): string {
  const files = readdirSync(HIGHLIGHTS)
    .filter((name) => name.endsWith(".md"))
    .map((name) => ({ file: name, text: readFileSync(join(HIGHLIGHTS, name), "utf8") }));
  return `${JSON.stringify(tipsFromHighlights(files), null, 2)}\n`;
}

if (import.meta.main) {
  const next = generatedTips();
  if (process.argv.includes("--check")) {
    if (readFileSync(GENERATED, "utf8") !== next) {
      console.error("tips.generated.json is stale: run bun scripts/gen-feature-tips.ts");
      process.exit(1);
    }
  } else writeFileSync(GENERATED, next);
}
