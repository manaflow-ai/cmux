import { routing, type Locale } from "./routing";

type LanguagePreference = {
  tag: string;
  quality: number;
  index: number;
};

export function preferredLocaleFromAcceptLanguage(
  acceptedLanguages: string,
  availableLocales: readonly Locale[] = routing.locales,
  fallbackLocale: Locale = routing.defaultLocale,
): Locale {
  const preferences = parseAcceptLanguage(acceptedLanguages);
  const preferred = availableLocales
    .map((locale, localeIndex) => ({
      locale,
      localeIndex,
      ...effectiveLanguageQuality(locale, preferences),
    }))
    .filter(({ quality }) => quality > 0)
    .sort(
      (left, right) =>
        right.quality - left.quality ||
        left.index - right.index ||
        right.specificity - left.specificity ||
        left.localeIndex - right.localeIndex,
    )[0];

  if (preferred) return preferred.locale;
  if (availableLocales.includes(fallbackLocale)) return fallbackLocale;
  return availableLocales[0] ?? fallbackLocale;
}

function parseAcceptLanguage(acceptedLanguages: string): LanguagePreference[] {
  return acceptedLanguages
    .split(",")
    .map((preference, index) => {
      const [rawTag = "", ...parameters] = preference.trim().split(";");
      const qualityParameter = parameters.find((parameter) =>
        /^q\s*=/iu.test(parameter.trim()),
      );
      const qualityValue = qualityParameter?.split("=")[1]?.trim();
      const quality =
        qualityValue === undefined
          ? 1
          : /^(?:0(?:\.\d{0,3})?|1(?:\.0{0,3})?)$/u.test(qualityValue)
            ? Number(qualityValue)
            : Number.NaN;
      return { tag: rawTag.trim().toLowerCase(), quality, index };
    })
    .filter(
      ({ tag, quality }) =>
        tag.length > 0 &&
        Number.isFinite(quality) &&
        quality >= 0 &&
        quality <= 1,
    );
}

function effectiveLanguageQuality(
  locale: Locale,
  preferences: LanguagePreference[],
): Pick<LanguagePreference, "quality" | "index"> & { specificity: number } {
  const matches = preferences
    .map((preference) => ({
      ...preference,
      specificity: languageMatchSpecificity(locale, preference.tag),
    }))
    .filter(({ specificity }) => specificity >= 0);
  const highestSpecificity = Math.max(
    -1,
    ...matches.map(({ specificity }) => specificity),
  );

  return matches
    .filter(({ specificity }) => specificity === highestSpecificity)
    .reduce(
      (best, preference) =>
        preference.quality > best.quality ||
        (preference.quality === best.quality && preference.index < best.index)
          ? preference
          : best,
      { quality: 0, index: Number.POSITIVE_INFINITY, specificity: highestSpecificity },
    );
}

function languageMatchSpecificity(locale: Locale, acceptedTag: string): number {
  if (acceptedTag === "*") return 0;
  const normalizedLocale = locale.toLowerCase();
  if (acceptedTag === normalizedLocale) return 2;
  return acceptedTag.split("-")[0] === normalizedLocale.split("-")[0] ? 1 : -1;
}
