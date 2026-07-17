import type { AbstractIntlMessages } from "next-intl";
import { routing, type Locale } from "./routing";

export function deepMergeMessages(
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

export async function loadMessages(locale: Locale): Promise<AbstractIntlMessages> {
  const localeMessages = (await import(`../messages/${locale}.json`)).default;
  if (locale === routing.defaultLocale) return localeMessages;

  const defaultMessages = (await import(`../messages/${routing.defaultLocale}.json`)).default;
  return deepMergeMessages(defaultMessages, localeMessages);
}
