import { createTranslator } from "use-intl/core";
import enMessages from "../../messages/en.json";
import type { AbstractIntlMessages } from "use-intl/core";

/** The English catalog used by the team page tests. */
export const teamsTestMessages = enMessages as unknown as AbstractIntlMessages;

/** A `next-intl` stand-in for `renderToStaticMarkup` tests of the team pages. */
export function teamsNextIntlMock() {
  const translator = (namespace?: string) =>
    createTranslator({
      locale: "en",
      messages: teamsTestMessages,
      namespace: namespace as never,
      timeZone: "UTC",
    });
  return {
    useTranslations: translator,
    useLocale: () => "en",
    useFormatter: () => ({
      dateTime: (date: Date) => date.toISOString().slice(0, 10),
    }),
  };
}
