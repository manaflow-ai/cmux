import { expect, test } from "bun:test";
import { readdirSync, readFileSync, statSync } from "node:fs";
import path from "node:path";
import { generate, LOCALES } from "../../scripts/settings/generate-strings.mjs";
import strings from "./generated/strings.json";
import { schema } from "./schema";
import { resolveLocale } from "./strings";

const catalog = strings as Record<string, Record<string, string>>;
const here = path.dirname(new URL(import.meta.url).pathname);

function sources(dir: string): string[] {
  return readdirSync(dir).flatMap((name) => {
    const file = path.join(dir, name);
    if (statSync(file).isDirectory()) return name === "generated" ? [] : sources(file);
    return /\.(ts|tsx)$/.test(name) && !/\.test\./.test(name) ? [file] : [];
  });
}

test("generated/strings.json is fresh (generate-strings --check)", () => {
  const { json, errors } = generate();
  expect(errors).toEqual([]);
  expect(readFileSync(path.join(here, "generated/strings.json"), "utf8")).toBe(json);
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
