import { describe, expect, test } from "bun:test";

import englishMessages from "../messages/en.json";

const translatedLocales = [
  "ar",
  "bs",
  "da",
  "de",
  "es",
  "fr",
  "it",
  "km",
  "ko",
  "no",
  "pl",
  "pt-BR",
  "ru",
  "th",
  "tr",
  "uk",
  "zh-CN",
  "zh-TW",
] as const;
const anchorKeys = ["anchorNew", "anchorClose"] as const;
const untranslatedActionLabels = ["Ungroup Workspaces", "Delete Group"] as const;
// These Khmer native menu entries currently use their English localizations.
const localesUsingEnglishNativeActionLabels = new Set<
  (typeof translatedLocales)[number]
>(["km"]);

type WorkspaceGroupCatalog = {
  docs?: {
    workspaceGroups?: Partial<
      Record<(typeof anchorKeys)[number], string>
    >;
  };
};

describe("workspace group documentation localization", () => {
  test("covers the 18 locales that do not use the maintained English or Japanese catalogs", () => {
    expect(translatedLocales).toHaveLength(18);
  });

  for (const locale of translatedLocales) {
    test(`${locale} provides locale-specific anchor guidance`, async () => {
      const messages = (await import(`../messages/${locale}.json`))
        .default as WorkspaceGroupCatalog;
      const workspaceGroups = messages.docs?.workspaceGroups;

      for (const key of anchorKeys) {
        const translation = workspaceGroups?.[key];
        expect(translation).toBeString();
        expect(translation).not.toBe(englishMessages.docs.workspaceGroups[key]);
      }

      for (const label of untranslatedActionLabels) {
        if (localesUsingEnglishNativeActionLabels.has(locale)) {
          expect(workspaceGroups?.anchorClose).toContain(label);
        } else {
          expect(workspaceGroups?.anchorClose).not.toContain(label);
        }
      }
    });
  }
});
