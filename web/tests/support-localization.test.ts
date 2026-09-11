import { describe, expect, test } from "bun:test";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { PricingCompareTable } from "../app/components/pricing-shared";

import arabicMessages from "../messages/ar.json";
import bosnianMessages from "../messages/bs.json";
import danishMessages from "../messages/da.json";
import germanMessages from "../messages/de.json";
import englishMessages from "../messages/en.json";
import spanishMessages from "../messages/es.json";
import frenchMessages from "../messages/fr.json";
import italianMessages from "../messages/it.json";
import japaneseMessages from "../messages/ja.json";
import khmerMessages from "../messages/km.json";
import koreanMessages from "../messages/ko.json";
import norwegianMessages from "../messages/no.json";
import polishMessages from "../messages/pl.json";
import brazilianPortugueseMessages from "../messages/pt-BR.json";
import russianMessages from "../messages/ru.json";
import thaiMessages from "../messages/th.json";
import turkishMessages from "../messages/tr.json";
import ukrainianMessages from "../messages/uk.json";
import simplifiedChineseMessages from "../messages/zh-CN.json";
import traditionalChineseMessages from "../messages/zh-TW.json";
import { locales } from "../i18n/routing";
import {
  flattenCatalog,
  parityLocales,
  validateCatalog,
} from "../tools/localization-catalog";

const messagesByLocale = {
  en: englishMessages,
  ja: japaneseMessages,
  "zh-CN": simplifiedChineseMessages,
  "zh-TW": traditionalChineseMessages,
  ko: koreanMessages,
  de: germanMessages,
  es: spanishMessages,
  fr: frenchMessages,
  it: italianMessages,
  da: danishMessages,
  pl: polishMessages,
  ru: russianMessages,
  bs: bosnianMessages,
  ar: arabicMessages,
  no: norwegianMessages,
  "pt-BR": brazilianPortugueseMessages,
  th: thaiMessages,
  tr: turkishMessages,
  km: khmerMessages,
  uk: ukrainianMessages,
} as const;

const supportEmail = "founders@manaflow.com";

const traditionalChineseForbiddenCharacters = new Set(
  [..."发帐复终运检销访虚拟网浏览会话确认显码设备连团队楼库闭键证体执负载选项层优环变导这过开关统实时间对纪仅转应为户响该线还标识组书电机盘继续断试级价计费审录读问处们区条规则频现视许进评类题页个业专吗么让长别样备宽"],
);

// Long-form sentences that any genuine translation must render differently
// from the English catalog. Short labels ("Discord", "Support") may
// legitimately match English and are excluded.
const mustDifferFromEnglishPaths = [
  ["metaDescription"],
  ["title"],
  ["body"],
  ["form", "message"],
  ["form", "privacy"],
  ["form", "success"],
  ["form", "error"],
] as const;

type Json = string | number | boolean | null | Json[] | { [key: string]: Json };

function shape(value: Json): Json {
  if (Array.isArray(value)) return value.map(shape);
  if (typeof value === "object" && value !== null) {
    return Object.fromEntries(
      Object.keys(value)
        .sort()
        .map((key) => [key, shape(value[key])]),
    );
  }
  return typeof value;
}

function leafStrings(value: Json): string[] {
  if (Array.isArray(value)) return value.flatMap(leafStrings);
  if (typeof value === "object" && value !== null) {
    return Object.values(value).flatMap(leafStrings);
  }
  return typeof value === "string" ? [value] : [];
}

function at(value: Json, path: readonly string[]): string {
  let current: Json = value;
  for (const key of path) {
    current = (current as { [key: string]: Json })[key];
  }
  return current as string;
}

describe("support page localization", () => {
  test("covers every routed locale", () => {
    expect(Object.keys(messagesByLocale).sort()).toEqual([...locales].sort());
  });

  for (const [locale, messages] of Object.entries(messagesByLocale)) {
    const support = (messages as { support: Json }).support;
    const footer = (messages as { footer: { support?: string } }).footer;

    test(`${locale} ships its own support catalog instead of English fallback`, () => {
      // Same key tree and array lengths as English, so no key silently
      // falls back through deepMergeMessages.
      expect(shape(support)).toEqual(
        shape((englishMessages as { support: Json }).support),
      );
      expect(
        leafStrings(support).every((value) => value.trim().length > 0),
      ).toBe(true);

      if (locale !== "en") {
        for (const path of mustDifferFromEnglishPaths) {
          expect(at(support, path)).not.toBe(
            at((englishMessages as { support: Json }).support, path),
          );
        }
      }
    });

    test(`${locale} keeps the support email address intact`, () => {
      const channels = support as {
        channels: { email: { label: string } };
        form: { success: string; error: string };
      };
      expect(channels.channels.email.label).toBe(supportEmail);
      expect(channels.form.success).toContain(supportEmail);
      expect(channels.form.error).toContain(supportEmail);
    });

    test(`${locale} links the support page from the footer`, () => {
      expect(typeof footer.support).toBe("string");
      expect(footer.support?.trim().length).toBeGreaterThan(0);
    });
  }

  test("zh-TW is not a copy of the zh-CN catalog", () => {
    const simplified = leafStrings(
      (simplifiedChineseMessages as { support: Json }).support,
    ).join("\n");
    const traditional = leafStrings(
      (traditionalChineseMessages as { support: Json }).support,
    ).join("\n");
    expect(traditional).not.toBe(simplified);
    // Simplified-only characters that must not leak into the Traditional catalog.
    for (const fragment of ["发送", "帐户", "报告", "订阅", "文档", "请"]) {
      expect(traditional).not.toContain(fragment);
    }
  });

  test("zh-TW does not contain Simplified-only characters", () => {
    const offenders = flattenCatalog(
      traditionalChineseMessages as unknown as Json,
    ).flatMap(({ path, value }) => {
      if (typeof value !== "string") return [];
      const characters = [
        ...new Set(
          [...value].filter((character) =>
            traditionalChineseForbiddenCharacters.has(character),
          ),
        ),
      ];
      return characters.length > 0 ? [`${path}: ${characters.join(", ")}`] : [];
    });

    expect(offenders).toEqual([]);
  });
});

describe("website message catalog parity", () => {
  test("renders pricing availability as icons in every release locale", () => {
    for (const locale of parityLocales) {
      const { pricing } = messagesByLocale[locale];
      const html = renderToStaticMarkup(createElement(PricingCompareTable, {
        rows: [pricing.compare.rows[0], pricing.compare.rows[5]],
        names: { free: "", pro: "", team: "", enterprise: "" },
        prices: { free: "", pro: "", team: "", enterprise: "" },
      }));
      expect(html.match(/<svg /g)?.length ?? 0).toBe(7);
      expect(html.match(/aria-label="Not included"/g)?.length ?? 0).toBe(1);
    }
  });

  test("preserves string-valued feature flags", async () => {
    expect(await validateCatalog("ar", { included: "true" }, { included: "true" })).toEqual([]);
    expect((await validateCatalog("ar", { included: "true" }, { included: "صحيح" })).map(({ message }) => message)).toEqual(["invalid message value"]);
  });

  test("preserves product names instead of translating their literal meanings", async () => {
    for (const [source, translation] of [
      ["Homebrew", "البيرة المنزلية"],
      ["Ghostty", "幽靈般的"],
      ["oh-my-pi", "Oh mein Pi"],
      ["tmux", "多路复用器"],
    ]) {
      const issues = await validateCatalog("ar", { name: source }, { name: translation });
      expect(issues.map(({ message }) => message)).toEqual(["translated product name"]);
      expect(await validateCatalog("ar", { name: source }, { name: source })).toEqual([]);
    }
  });

  test("rejects non-text replacements and changes to catalog flags", async () => {
    for (const value of [42, true, null]) {
      const issues = await validateCatalog(
        "fr",
        { message: "Read the guide" },
        { message: value },
      );
      expect(issues.map(({ message }) => message)).toEqual(["invalid message value"]);
    }
    expect(
      await validateCatalog("fr", { vault: true }, { vault: true }),
    ).toEqual([]);
    expect(
      (await validateCatalog("fr", { vault: true }, { vault: false })).map(
        ({ message }) => message,
      ),
    ).toEqual(["invalid message value"]);
  });

  test("does not allow English prose merely because it starts with a URL", async () => {
    const source = { message: "https://cmux.com has installation instructions" };
    expect(
      (await validateCatalog("fr", source, source)).map(({ message }) => message),
    ).toEqual(["English-identical value"]);
    const token = { message: "https://cmux.com/docs/getting-started" };
    expect(await validateCatalog("fr", token, token)).toEqual([]);
  });

  test("rejects rich-text tags that lose translated link text", async () => {
    const issues = await validateCatalog(
      "es",
      { message: "Read the <link>guide</link>." },
      { message: "Consulte la <link></link>." },
    );

    expect(issues.map(({ path, message }) => [path, message])).toEqual([
      ["message", "rich-text tag mismatch"],
    ]);
  });

  test("rejects mixed-case rich-text tags that lose translated link text", async () => {
    const issues = await validateCatalog(
      "de",
      { message: "Open <Link>guide</link><br/>." },
      { message: "Öffne <Link></link><br/>." },
    );

    expect(issues.map(({ path, message }) => [path, message])).toEqual([
      ["message", "rich-text tag mismatch"],
    ]);
  });

  test("keeps the nine release locales complete and translated", async () => {
    const english = englishMessages as unknown as Json;
    const catalogs = messagesByLocale as unknown as Record<string, Json>;
    for (const locale of parityLocales) {
      expect(await validateCatalog(locale, english, catalogs[locale])).toEqual([]);
    }
  });
});
