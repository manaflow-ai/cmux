import { getRequestConfig } from "next-intl/server";
import type { AbstractIntlMessages } from "next-intl";
import { routing } from "./routing";

function deepMergeMessages(
  base: AbstractIntlMessages,
  override: AbstractIntlMessages,
): AbstractIntlMessages {
  const result: AbstractIntlMessages = { ...base };

  for (const key of Object.keys(override)) {
    const baseValue = result[key];
    const overrideValue = override[key];

    if (
      typeof baseValue === "object" &&
      baseValue !== null &&
      !Array.isArray(baseValue) &&
      typeof overrideValue === "object" &&
      overrideValue !== null &&
      !Array.isArray(overrideValue)
    ) {
      result[key] = deepMergeMessages(
        baseValue as AbstractIntlMessages,
        overrideValue as AbstractIntlMessages,
      );
    } else {
      result[key] = overrideValue;
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

  if (locale === routing.defaultLocale) {
    return {
      locale,
      messages: localeMessages,
    };
  }

  const defaultMessages = (await import(`../messages/${routing.defaultLocale}.json`)).default;

  return {
    locale,
    // Keep localized pages rendering when a non-English bundle is missing
    // a key that still exists in English.
    messages: deepMergeMessages(defaultMessages, localeMessages),
  };
});
