"use client";

import { useLocale, useTranslations } from "next-intl";
import { useRouter, usePathname } from "../../../i18n/navigation";
import { locales, localeNames, type Locale } from "../../../i18n/routing";

export function LanguageSwitcher() {
  const locale = useLocale() as Locale;
  const t = useTranslations("footer");
  const router = useRouter();
  const pathname = usePathname();

  function onChange(e: React.ChangeEvent<HTMLSelectElement>) {
    const newLocale = e.target.value as Locale;
    const qs = typeof window !== "undefined"
      ? window.location.search + window.location.hash
      : "";
    router.replace(pathname + qs, { locale: newLocale });
  }

  return (
    <div className="flex max-w-full shrink-0 items-center gap-2 text-muted">
      <svg
        width="14"
        height="14"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        strokeWidth="2"
        strokeLinecap="round"
        strokeLinejoin="round"
        className="shrink-0"
        aria-hidden="true"
      >
        <circle cx="12" cy="12" r="10" />
        <path d="M2 12h20" />
        <path d="M12 2a15.3 15.3 0 0 1 4 10 15.3 15.3 0 0 1-4 10 15.3 15.3 0 0 1-4-10 15.3 15.3 0 0 1 4-10z" />
      </svg>
      <div className="relative w-40">
        <select
          value={locale}
          onChange={onChange}
          className="block w-full appearance-none bg-transparent border-none pr-5 text-xs cursor-pointer transition-colors hover:text-foreground focus:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-1"
          aria-label={t("language")}
        >
          {locales.map((loc) => (
            <option key={loc} value={loc}>
              {localeNames[loc]}
            </option>
          ))}
        </select>
        <svg
          width="12"
          height="12"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          strokeWidth="2"
          strokeLinecap="round"
          strokeLinejoin="round"
          className="pointer-events-none absolute right-0 top-1/2 -translate-y-1/2 shrink-0"
          aria-hidden="true"
        >
          <path d="m6 9 6 6 6-6" />
        </svg>
      </div>
    </div>
  );
}
