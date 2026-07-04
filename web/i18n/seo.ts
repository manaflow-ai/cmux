import { locales } from "./routing";

const BASE = "https://cmux.com";

/**
 * Build the full alternates object (canonical + hreflang languages)
 * for a given locale and path. Use in every generateMetadata that
 * sets alternates so child metadata doesn't wipe parent hreflang.
 */
export function buildAlternates(
  locale: string,
  path: string,
  availableLocales: readonly string[] = locales,
) {
  const languages: Record<string, string> = {};
  for (const loc of availableLocales) {
    languages[loc] =
      loc === "en" ? `${BASE}${path}` : `${BASE}/${loc}${path}`;
  }
  languages["x-default"] = `${BASE}${path}`;

  const canonical =
    locale === "en" ? `${BASE}${path}` : `${BASE}/${locale}${path}`;

  return { canonical, languages };
}

export function buildAlternateLinkHeader(
  origin: string,
  path: string,
  availableLocales: readonly string[] = locales,
) {
  const entries = availableLocales.map((locale) => {
    const url = localizedUrl(origin, locale, path);
    return `<${url}>; rel="alternate"; hreflang="${locale}"`;
  });
  entries.push(
    `<${localizedUrl(origin, "en", path)}>; rel="alternate"; hreflang="x-default"`,
  );
  return entries.join(", ");
}

function localizedUrl(origin: string, locale: string, path: string) {
  const pathname = locale === "en" ? path : `/${locale}${path}`;
  return new URL(pathname, origin).toString();
}
