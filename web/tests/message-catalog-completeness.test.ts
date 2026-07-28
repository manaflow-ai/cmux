import { describe, expect, test } from "bun:test";
import { locales } from "../i18n/routing";
import englishMessages from "../messages/en.json";

describe("message catalog completeness", () => {
  test("defines every English message in every supported locale", async () => {
    for (const locale of locales) {
      if (locale === "en") continue;

      const messages = (
        await import(`../messages/${locale}.json`)
      ).default as unknown;
      expect(missingMessagePaths(englishMessages, messages)).toEqual([]);
    }
  });

  test("provides translated legal documents in every supported locale", async () => {
    const english = englishMessages as unknown as LegalMessages;
    expect(english.legal.terms.title).toBe("Terms of Service");
    expect(english.legal.eula.title).toBe("EULA");

    for (const locale of locales) {
      if (locale === "en") continue;

      const messages = (
        await import(`../messages/${locale}.json`)
      ).default as unknown as LegalMessages;
      expect(messages.legal.terms.title).not.toBe(english.legal.terms.title);
      expect(messages.legal.terms.introduction.acceptance).not.toBe(
        english.legal.terms.introduction.acceptance,
      );
      expect(messages.legal.eula.introduction.readCarefully).not.toBe(
        english.legal.eula.introduction.readCarefully,
      );
      expect(messages.legal.eula.sections.license.scopeBody).not.toBe(
        english.legal.eula.sections.license.scopeBody,
      );
    }
  });
});

type LegalMessages = {
  legal: {
    terms: {
      title: string;
      introduction: { acceptance: string };
    };
    eula: {
      title: string;
      introduction: { readCarefully: string };
      sections: { license: { scopeBody: string } };
    };
  };
};

function missingMessagePaths(
  source: unknown,
  target: unknown,
  path = "",
): string[] {
  if (Array.isArray(source)) {
    if (!Array.isArray(target)) return [path];
    return source.flatMap((value, index) =>
      missingMessagePaths(value, target[index], `${path}[${index}]`),
    );
  }

  if (isRecord(source)) {
    if (!isRecord(target)) return [path];
    return Object.entries(source).flatMap(([key, value]) =>
      missingMessagePaths(
        value,
        target[key],
        path.length > 0 ? `${path}.${key}` : key,
      ),
    );
  }

  return target === undefined || typeof target !== typeof source ? [path] : [];
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
