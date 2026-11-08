import { describe, expect, test } from "bun:test";
import { errorBoundaryCopy, resolveErrorBoundaryLocale } from "../i18n/error-boundary-copy";
import { locales } from "../i18n/routing";

describe("error boundary copy", () => {
  test("covers every routed locale with non-empty strings", () => {
    for (const locale of locales) {
      for (const value of Object.values(errorBoundaryCopy[locale])) {
        expect(value.trim().length).toBeGreaterThan(0);
      }
    }
  });

  test("prefers the document locale, then the browser", () => {
    expect(resolveErrorBoundaryLocale("ja", "de", "fr-FR")).toBe("ja");
    expect(resolveErrorBoundaryLocale(undefined, "", "fr-FR")).toBe("fr");
    expect(resolveErrorBoundaryLocale(undefined, null, "zh-Hant-TW")).toBe("zh-TW");
    expect(resolveErrorBoundaryLocale(undefined, null, "nb-NO")).toBe("no");
    expect(resolveErrorBoundaryLocale("xx", null, "pt-PT")).toBe("pt-BR");
    expect(resolveErrorBoundaryLocale(undefined, null, "xx")).toBe("en");
  });
});
