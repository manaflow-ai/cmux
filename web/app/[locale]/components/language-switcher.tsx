"use client";

import { useLocale } from "next-intl";
import { locales, localeNames, type Locale } from "../../../i18n/routing";

export function LanguageSwitcher() {
  const locale = useLocale() as Locale;

  function onChange(e: React.ChangeEvent<HTMLSelectElement>) {
    const newLocale = e.target.value as Locale;
    const currentPathname = window.location.pathname;
    const currentLocale = locales.find((candidate) =>
      currentPathname === `/${candidate}` || currentPathname.startsWith(`/${candidate}/`),
    );
    const currentPrefix = currentLocale ? `/${currentLocale}` : "";
    const pathname = currentPathname === currentPrefix
      ? "/"
      : currentPrefix.length > 0 && currentPathname.startsWith(`${currentPrefix}/`)
        ? currentPathname.slice(currentPrefix.length)
        : currentPathname;
    const prefix = newLocale === "en" ? "" : `/${newLocale}`;
    const localizedPathname = pathname === "/" ? prefix || "/" : `${prefix}${pathname}`;
    // Keep next-intl's locale cookie in sync before the full navigation. This
    // prevents the default-locale route from immediately redirecting back to
    // the previous locale while the server renders the fresh document.
    document.cookie = `NEXT_LOCALE=${newLocale}; Path=/; Max-Age=31536000; SameSite=Lax`;
    window.location.href = localizedPathname + window.location.search + window.location.hash;
  }

  return (
    <div className="flex items-center gap-2">
      <svg
        width="14"
        height="14"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        strokeWidth="2"
        strokeLinecap="round"
        strokeLinejoin="round"
        className="text-muted"
        aria-hidden="true"
      >
        <circle cx="12" cy="12" r="10" />
        <path d="M2 12h20" />
        <path d="M12 2a15.3 15.3 0 0 1 4 10 15.3 15.3 0 0 1-4 10 15.3 15.3 0 0 1-4-10 15.3 15.3 0 0 1 4-10z" />
      </svg>
      <select
        value={locale}
        onChange={onChange}
        className="text-xs text-muted bg-transparent border-none cursor-pointer hover:text-foreground transition-colors focus:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-1"
        aria-label="Language"
      >
        {locales.map((loc) => (
          <option key={loc} value={loc}>
            {localeNames[loc]}
          </option>
        ))}
      </select>
    </div>
  );
}
