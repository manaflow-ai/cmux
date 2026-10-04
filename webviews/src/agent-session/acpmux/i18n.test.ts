import { expect, test } from "bun:test";
import { paneLanguage, STRING_TABLES, translate } from "./i18n";

test("every language has every key, with the same placeholders", () => {
  const keys = Object.keys(STRING_TABLES.en!).sort();
  for (const [language, table] of Object.entries(STRING_TABLES)) {
    expect([language, Object.keys(table).sort()]).toEqual([language, keys]);
    for (const key of keys) {
      const placeholders = (text: string) => [...text.matchAll(/\{(\w+)\}/g)].map((m) => m[1]).sort();
      expect(placeholders(table[key as keyof typeof table])).toEqual(
        placeholders(STRING_TABLES.en![key as keyof typeof table]),
      );
    }
  }
});

test("picks Japanese for a Japanese app, English otherwise", () => {
  expect(paneLanguage(["ja-JP", "en-US"])).toBe("ja");
  expect(paneLanguage(["fr-FR", "en-GB"])).toBe("en");
  expect(paneLanguage([])).toBe("en");
  expect(translate("turn.previous.other", { n: 34 }, "en")).toBe("34 previous messages");
  expect(translate("turn.previous.other", { n: 34 }, "ja")).toBe("以前のメッセージ 34 件");
});
