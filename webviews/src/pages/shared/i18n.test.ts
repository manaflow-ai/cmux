import { describe, expect, test } from "bun:test";
import table from "../history/generated/strings.json";
import { createStrings, resolveLanguage } from "./i18n";

const codes = ["en", "ja", "zh-Hans", "zh-Hant", "pt-BR", "nb", "de"];

describe("resolveLanguage", () => {
  test("exact, base and regional tags map to Apple codes", () => {
    expect(resolveLanguage(["ja-JP"], codes)).toBe("ja");
    expect(resolveLanguage(["ja"], codes)).toBe("ja");
    expect(resolveLanguage(["zh-CN"], codes)).toBe("zh-Hans");
    expect(resolveLanguage(["zh-Hant-TW"], codes)).toBe("zh-Hant");
    expect(resolveLanguage(["zh-HK"], codes)).toBe("zh-Hant");
    expect(resolveLanguage(["pt-PT"], codes)).toBe("pt-BR");
    expect(resolveLanguage(["no"], codes)).toBe("nb");
  });

  test("the first supported preference wins; nothing supported is English", () => {
    expect(resolveLanguage(["xx", "de-AT", "ja"], codes)).toBe("de");
    expect(resolveLanguage(["xx"], codes)).toBe("en");
  });
});

describe("generated History table", () => {
  test("has English and Japanese for every key the page uses", () => {
    const keys = Object.keys(table.en);
    expect(keys).toContain("page.disconnected");
    for (const key of keys) expect((table as Record<string, Record<string, string>>).ja[key]).toBeTruthy();
  });

  test("strings fall back to English, then to the key", () => {
    const ja = createStrings(table, ["ja-JP"]);
    expect(ja.language).toBe("ja");
    expect(ja.t("page.title")).toBe("履歴");
    expect(createStrings({ en: { a: "A" }, ja: {} }, ["ja"]).t("a")).toBe("A");
    expect(createStrings(table, ["en"]).t("missing.key")).toBe("missing.key");
  });
});
