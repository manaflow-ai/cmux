import { createTranslator } from "use-intl/core";
import enMessages from "../../messages/en.json";
import teamsMessages from "../../messages-staging/teams.en.json";
import type { AbstractIntlMessages } from "use-intl/core";
import { deepMergeMessages } from "../../i18n/messages";

/** The English catalog as it will be once the staged team strings merge. */
export const teamsTestMessages = deepMergeMessages(
  enMessages as unknown as AbstractIntlMessages,
  teamsMessages,
);

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
