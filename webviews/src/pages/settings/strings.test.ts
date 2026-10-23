import { expect, test } from "bun:test";
import "./testCatalog";
import { readdirSync, readFileSync, statSync } from "node:fs";
import path from "node:path";
import { generate, LOCALES, PAGES } from "../../../scripts/pages/gen-strings.mjs";
import strings from "./generated/strings.json";
import { schema } from "./schema";
import { resolveLocale } from "./strings";

const catalog = strings as Record<string, Record<string, string>>;
const here = import.meta.dir;

function sources(dir: string): string[] {
  return readdirSync(dir).flatMap((name) => {
    const file = path.join(dir, name);
    if (statSync(file).isDirectory()) return name === "generated" ? [] : sources(file);
    return /\.(ts|tsx)$/.test(name) && !/\.test\./.test(name) ? [file] : [];
  });
}

// The table is build output (#21946) that the test preload writes, so comparing it with the
// generator would compare the generator with itself. What can fail is the catalogs: every key the
// schema names must be translated in all 21 locales.
test("the settings strings generate with no missing translation", () => {
  expect(generate(PAGES.settings).errors).toEqual([]);
});

test("every key the page uses exists in all 21 locales", () => {
  expect(Object.keys(catalog)).toEqual(LOCALES);
  expect(LOCALES.length).toBe(21);
  const used = new Set<string>();
  for (const file of sources(here)) {
    for (const match of readFileSync(file, "utf8").matchAll(/\bt\("([^"]+)"/g)) used.add(match[1]!);
  }
  for (const section of schema.sections) used.add(section.title.key!);
  for (const row of schema.rows) {
    for (const value of [
      row.title,
      row.help,
      row.summary,
      row.group,
      row.default_label,
      ...(row.choices ?? []).map((c) => c.title),
    ]) {
      if (value?.key) used.add(value.key);
    }
  }
  expect(used.size).toBeGreaterThan(200);
  const missing = LOCALES.flatMap((locale: string) =>
    [...used].filter((key) => !catalog[locale]?.[key]).map((key) => `${locale}:${key}`),
  );
  expect(missing).toEqual([]);
});

test("app and browser language tags resolve onto catalog locales", () => {
  expect(resolveLocale("ja")).toBe("ja");
  expect(resolveLocale("ja-JP")).toBe("ja");
  expect(resolveLocale("pt-PT")).toBe("pt-BR");
  expect(resolveLocale("zh-TW")).toBe("zh-Hant");
  expect(resolveLocale("zh_CN")).toBe("zh-Hans");
  expect(resolveLocale("zh-Hant-HK")).toBe("zh-Hant");
  expect(resolveLocale("no")).toBe("nb");
  expect(resolveLocale("xx-YY")).toBe("en");
  expect(resolveLocale(null)).toBe("en");
});
