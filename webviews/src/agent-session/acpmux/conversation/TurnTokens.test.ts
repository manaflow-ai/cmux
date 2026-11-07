// The token hover is one count per row in every language (Leo, 2026-11-07: "you just have this,
// like, one, one and a half words on a second line").
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";

const catalog = JSON.parse(readFileSync(new URL("../Localizable.xcstrings", import.meta.url), "utf8")) as {
  strings: Record<string, { localizations: Record<string, { stringUnit: { value: string } }> }>;
};

test("every language's token hover puts each count on its own row", () => {
  const entry = catalog.strings["turn.tokens.detail"]!;
  const languages = Object.keys(entry.localizations);
  expect(languages.length).toBeGreaterThan(1);
  for (const language of languages) {
    const rows = entry.localizations[language]!.stringUnit.value.split("\n");
    expect({ language, rows: rows.length }).toEqual({ language, rows: 4 });
    expect(rows.map((row) => row.match(/\{(\w+)\}/)?.[1])).toEqual(["output", "input", "cacheRead", "cacheWrite"]);
    for (const row of rows) expect(row).not.toContain(" · ");
  }
});
