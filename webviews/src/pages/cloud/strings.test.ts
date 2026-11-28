import { describe, expect, test } from "bun:test";
import fs from "node:fs";
import table from "./generated/strings.json";
import { L } from "./strings";

// The languages scripts/cmux-next/check-l10n.sh requires for every cmux-next table.
const LANGS = [
  "en",
  "ar",
  "bs",
  "da",
  "de",
  "es",
  "fr",
  "it",
  "ja",
  "km",
  "ko",
  "nb",
  "pl",
  "pt-BR",
  "ru",
  "th",
  "tr",
  "uk",
  "vi",
  "zh-Hans",
  "zh-Hant",
] as const;

const strings = table as Record<string, Record<string, string>>;
const keys = Object.values(L);
const source = (
  JSON.parse(fs.readFileSync(new URL("./Localizable.xcstrings", import.meta.url), "utf8")) as {
    strings: Record<string, unknown>;
  }
).strings;

describe("Cloud page strings", () => {
  test("every key the page uses exists in English and Japanese", () => {
    const missing = keys.filter((key) => !strings.en?.[key] || !strings.ja?.[key]);
    expect(missing).toEqual([]);
  });

  test("every key has every language check-l10n requires", () => {
    const missing: string[] = [];
    for (const key of keys) for (const lang of LANGS) if (!strings[lang]?.[key]?.trim()) missing.push(`${key}:${lang}`);
    expect(missing).toEqual([]);
  });

  test("the catalog has no key the page does not use", () => {
    const used = new Set<string>(keys);
    expect(Object.keys(source).filter((key) => !used.has(key))).toEqual([]);
  });

  test("placeholders match English in every language", () => {
    const placeholders = (value: string) => (value.match(/\{[a-z]+\}/g) ?? []).sort().join(",");
    const wrong: string[] = [];
    for (const key of keys)
      for (const lang of LANGS) {
        const value = strings[lang]?.[key];
        if (value !== undefined && placeholders(value) !== placeholders(strings.en[key])) wrong.push(`${key}:${lang}`);
      }
    expect(wrong).toEqual([]);
  });
});
