import { expect, test } from "bun:test";
import { LOCALES } from "../../../scripts/pages/gen-strings.mjs";
import { paneLanguage, STRING_TABLES, translate } from "./i18n";

// The pane's strings come from acpmux/Localizable.xcstrings through the pages' generator
// (generated/strings.json), in every language the app ships.
test("every shipped language has every key, with the same placeholders", () => {
  expect(Object.keys(STRING_TABLES).sort()).toEqual([...(LOCALES as string[])].sort());
  const keys = Object.keys(STRING_TABLES.en!).sort();
  const placeholders = (text: string) => [...text.matchAll(/\{(\w+)\}/g)].map((m) => m[1]).sort();
  for (const [language, table] of Object.entries(STRING_TABLES)) {
    expect([language, Object.keys(table).sort()]).toEqual([language, keys]);
    for (const key of keys)
      expect([language, key, placeholders(table[key]!)]).toEqual([
        language,
        key,
        placeholders(STRING_TABLES.en![key]!),
      ]);
  }
});

test("picks the app's language among the shipped ones, English otherwise", () => {
  expect(paneLanguage(["ja-JP", "en-US"])).toBe("ja");
  expect(paneLanguage(["de-DE"])).toBe("de");
  expect(paneLanguage(["zh-TW"])).toBe("zh-Hant");
  expect(paneLanguage(["pt-PT"])).toBe("pt-BR");
  expect(paneLanguage(["xx-YY"])).toBe("en");
  expect(paneLanguage([])).toBe("en");
  expect(translate("turn.previous.other", { n: 34 }, "en")).toBe("34 previous messages");
  expect(translate("turn.previous.other", { n: 34 }, "ja")).toBe("以前のメッセージ 34 件");
});
