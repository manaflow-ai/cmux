import { preferredLocaleFromAcceptLanguage } from "../../../i18n/accept-language";
import { locales, type Locale } from "../../../i18n/routing";

/**
 * The proxy already resolved the viewer's app locale (cookie first, then
 * Accept-Language) into `x-next-intl-locale` for this route. Only fall back to
 * the raw Accept-Language header when that resolution is absent.
 */
export function publicationAccessLocale(headersList: Headers): Locale {
  const resolved = headersList.get("x-next-intl-locale")?.trim();
  if (resolved && (locales as readonly string[]).includes(resolved)) {
    return resolved as Locale;
  }
  return preferredLocaleFromAcceptLanguage(headersList.get("accept-language") ?? "");
}
