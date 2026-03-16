import { getRequestConfig } from "next-intl/server";
import { routing } from "./routing";
import type { AbstractIntlMessages } from "next-intl";

function deepMerge(base: AbstractIntlMessages, override: AbstractIntlMessages): AbstractIntlMessages {
  const result = { ...base };
  for (const key of Object.keys(override)) {
    if (
      typeof result[key] === "object" &&
      result[key] !== null &&
      typeof override[key] === "object" &&
      override[key] !== null
    ) {
      result[key] = deepMerge(
        result[key] as AbstractIntlMessages,
        override[key] as AbstractIntlMessages,
      );
    } else {
      result[key] = override[key];
    }
  }
  return result;
}

export default getRequestConfig(async ({ requestLocale }) => {
  let locale = await requestLocale;

  if (!locale || !routing.locales.includes(locale as typeof routing.locales[number])) {
    locale = routing.defaultLocale;
  }

  const localeMessages = (await import(`../messages/${locale}.json`)).default;

  // Merge with English as fallback so missing keys resolve to English text
  if (locale === "en") {
    return { locale, messages: localeMessages };
  }

  const enMessages = (await import("../messages/en.json")).default;
  return {
    locale,
    messages: deepMerge(enMessages, localeMessages),
  };
});
