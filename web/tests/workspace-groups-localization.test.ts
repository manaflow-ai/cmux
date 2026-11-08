import { describe, expect, test } from "bun:test";

import arabicMessages from "../messages/ar.json";
import bosnianMessages from "../messages/bs.json";
import danishMessages from "../messages/da.json";
import germanMessages from "../messages/de.json";
import englishMessages from "../messages/en.json";
import spanishMessages from "../messages/es.json";
import frenchMessages from "../messages/fr.json";
import italianMessages from "../messages/it.json";
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

const translatedMessagesByLocale = {
  ar: arabicMessages,
  bs: bosnianMessages,
  da: danishMessages,
  de: germanMessages,
  es: spanishMessages,
  fr: frenchMessages,
  it: italianMessages,
  km: khmerMessages,
  ko: koreanMessages,
  no: norwegianMessages,
  pl: polishMessages,
  "pt-BR": brazilianPortugueseMessages,
  ru: russianMessages,
  th: thaiMessages,
  tr: turkishMessages,
  uk: ukrainianMessages,
  "zh-CN": simplifiedChineseMessages,
  "zh-TW": traditionalChineseMessages,
} as const;
const anchorKeys = ["anchorNew", "anchorClose"] as const;
const untranslatedActionLabels = ["Ungroup Workspaces", "Delete Group"] as const;
// These Khmer native menu entries currently use their English localizations.
const localesUsingEnglishNativeActionLabels = new Set(["km"]);

describe("workspace group documentation localization", () => {
  test("covers the 18 locales that do not use the maintained English or Japanese catalogs", () => {
    expect(Object.keys(translatedMessagesByLocale)).toHaveLength(18);
  });

  for (const [locale, messages] of Object.entries(
    translatedMessagesByLocale,
  )) {
    test(`${locale} provides locale-specific anchor guidance`, () => {
      const workspaceGroups = messages.docs.workspaceGroups;

      for (const key of anchorKeys) {
        const translation = workspaceGroups[key];
        expect(translation).toBeString();
        expect(translation).not.toBe(englishMessages.docs.workspaceGroups[key]);
      }

      for (const label of untranslatedActionLabels) {
        if (localesUsingEnglishNativeActionLabels.has(locale)) {
          expect(workspaceGroups.anchorClose).toContain(label);
        } else {
          expect(workspaceGroups.anchorClose).not.toContain(label);
        }
      }
    });
  }
});
