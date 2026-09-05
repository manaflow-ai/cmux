"use client";

import { useLocale } from "next-intl";
import { getPathname, usePathname } from "../../../i18n/navigation";
import { locales, localeNames, type Locale } from "../../../i18n/routing";

function persistLocaleCookie(nextLocale: Locale) {
  // as-needed default-locale URLs are unprefixed (`/`, not `/en`). Middleware
  // otherwise keeps serving the previous NEXT_LOCALE (or Accept-Language)
  // after the client URL has already changed.
  document.cookie =
    `NEXT_LOCALE=${encodeURIComponent(nextLocale)}; Path=/; Max-Age=31536000; SameSite=Lax`;
}

export function LanguageSwitcher() {
  const locale = useLocale() as Locale;
  const pathname = usePathname();

  function onChange(e: React.ChangeEvent<HTMLSelectElement>) {
    const newLocale = e.target.value as Locale;
    if (newLocale === locale) return;
    const qs = window.location.search + window.location.hash;
    persistLocaleCookie(newLocale);
    // Full document navigation so html lang, title, and server-rendered copy
    // all come from one request. Client navigation through the instant cache
    // can keep the previous locale's shell after the `/en` → `/` redirect.
    window.location.assign(
      getPathname({ href: pathname, locale: newLocale }) + qs,
    );
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
