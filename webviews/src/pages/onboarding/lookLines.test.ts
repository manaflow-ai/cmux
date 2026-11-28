// Leo, 2026-11-27: "im not a fan of the descriptions on our themes and whatnot". The intro walk's
// look tiles and setup rows each say one short plain phrase, the rule looks.rs's `plain_phrase`
// holds for every look and theme: at most seven words, no colon or semicolon, no second sentence.
import { expect, test } from "bun:test";
import fs from "node:fs";

type Catalog = { strings: Record<string, { localizations?: { en?: { stringUnit?: { value?: string } } } }> };

const catalog = JSON.parse(fs.readFileSync(new URL("./Localizable.xcstrings", import.meta.url), "utf8")) as Catalog;

const LOOK_LINE = /^onboarding\.makeItYours\.(bundle|setup)\.[A-Za-z]+\.line$/;

test("every look and setup line in the intro walk is one short plain phrase", () => {
  const lines = Object.entries(catalog.strings)
    .filter(([key]) => LOOK_LINE.test(key))
    .map(([key, entry]) => [key, entry.localizations?.en?.stringUnit?.value ?? ""] as const);
  expect(lines.length).toBeGreaterThanOrEqual(5);
  for (const [key, line] of lines) {
    const words = line.trim().split(/\s+/).filter(Boolean);
    expect({ key, plain: words.length > 0 && words.length <= 7 && !/[:;]/.test(line) }).toEqual({ key, plain: true });
    expect({ key, sentences: line.trim().replace(/\.$/, "").split(/\.\s/).length }).toEqual({ key, sentences: 1 });
  }
});
