import { routing } from "@/i18n/routing";

/** Document URL of a non-dashboard page, honoring `localePrefix: "as-needed"`. */
export function localeHref(locale: string, path: string): string {
  const suffix = path.startsWith("/") ? path : `/${path}`;
  return locale === routing.defaultLocale ? suffix : `/${locale}${suffix === "/" ? "" : suffix}`;
}

export function localeHomeHref(locale: string): string {
  return localeHref(locale, "/");
}
