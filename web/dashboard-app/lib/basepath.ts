import { locales, routing } from "@/i18n/routing";

/**
 * The router basepath is the locale prefix only, so route paths keep their
 * public `/dashboard/...` form. `localePrefix: "as-needed"` omits the prefix
 * for the default locale.
 */
export function dashboardBasepath(pathname: string): string {
  const first = pathname.split("/")[1] ?? "";
  if ((locales as readonly string[]).includes(first) && first !== routing.defaultLocale) {
    return `/${first}`;
  }
  return "";
}
