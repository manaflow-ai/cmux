import { locales, routing, type Locale } from "./routing";

/**
 * Locales whose pages `next build` generates ahead of time.
 *
 * Production builds every locale. Development backends set
 * `CMUX_PRERENDER_LOCALES=en` because localized static generation dominates
 * their build time; the other locales still render on their first request.
 * The default locale is always included so every locale segment keeps at
 * least one build-time sample, which Cache Components requires.
 */
export function prerenderLocales(
  value: string | undefined = process.env.CMUX_PRERENDER_LOCALES,
): readonly Locale[] {
  const requested = (value ?? "")
    .split(",")
    .map((locale) => locale.trim())
    .filter(Boolean);
  if (requested.length === 0) return locales;

  const unknown = requested.filter(
    (locale) => !locales.includes(locale as Locale),
  );
  if (unknown.length > 0) {
    throw new Error(
      `CMUX_PRERENDER_LOCALES contains unknown locales: ${unknown.join(", ")}`,
    );
  }
  return locales.filter(
    (locale) => locale === routing.defaultLocale || requested.includes(locale),
  );
}
