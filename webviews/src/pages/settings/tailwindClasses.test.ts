// The page's Tailwind utilities, compiled as the app build does, define no class the page's own
// stylesheets use. Regression: Tailwind's `collapse` utility (`visibility: collapse`) matched the
// page's open/close class, so every search result and the No Results line stayed invisible and a
// search showed an empty pane. Unlayered page rules beat the utilities layer only for the
// properties they set, so a utility of the same name still adds its own.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { compileTailwind } from "../../../scripts/agent-pane/tailwindCompile.mjs";

const pageSheets = ["styles.css", "layout.css", "refined.css"];

function classNames(css: string): Set<string> {
  const text = css.replace(/\/\*[\s\S]*?\*\//g, "");
  return new Set([...text.matchAll(/\.(-?[_a-zA-Z][\w-]*)/g)].map((match) => match[1]!));
}

test("no Tailwind utility shares a name with a class of the page's own stylesheets", async () => {
  const utilities = await compileTailwind(path.join(import.meta.dir, "tailwind.css"));
  const compiled = classNames(utilities.slice(utilities.indexOf("@layer utilities")));
  const clashes = pageSheets.flatMap((sheet) =>
    [...classNames(readFileSync(path.join(import.meta.dir, sheet), "utf8"))]
      .filter((name) => compiled.has(name))
      .map((name) => `${sheet}: .${name}`),
  );
  expect(clashes).toEqual([]);
});
