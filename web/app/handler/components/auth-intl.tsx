import { Fragment, type ReactNode } from "react";
import { headers } from "next/headers";

import { preferredLocaleFromAcceptLanguage } from "../../../i18n/accept-language";
import { loadMessages } from "../../../i18n/messages";
import type { Locale } from "../../../i18n/routing";

export type AuthTranslate = (
  key: string,
  values?: Readonly<Record<string, string>>,
) => string;

export type AuthIntl = {
  readonly locale: Locale;
  readonly direction: "ltr" | "rtl";
  readonly t: AuthTranslate;
};

const RTL_LOCALES = new Set<string>(["ar"]);

/**
 * Resolves auth-page copy from `Accept-Language`.
 *
 * `/handler/*` sits outside the `[locale]` segment, so next-intl's request
 * config always reports the default locale here. Reading the header directly
 * is what the existing auth error page does, and it keeps these pages free of
 * a locale prefix that native and email links would have to know about.
 */
export async function authIntl(): Promise<AuthIntl> {
  const requestHeaders = await headers();
  const locale = preferredLocaleFromAcceptLanguage(
    requestHeaders.get("accept-language") ?? "",
  );
  const catalog = await loadMessages(locale);
  const namespace = (catalog.auth ?? {}) as Record<string, unknown>;
  return {
    locale,
    direction: RTL_LOCALES.has(locale) ? "rtl" : "ltr",
    t: (key, values) => {
      const template = namespace[key];
      if (typeof template !== "string") return key;
      if (!values) return template;
      return template.replace(
        /\{(\w+)\}/gu,
        (match, name: string) => values[name] ?? match,
      );
    },
  };
}

/**
 * Substitutes React nodes into a translated sentence.
 *
 * Legal notices need links inside the sentence, and the position of those
 * links differs by language. Splitting on the placeholders keeps the order the
 * translator chose instead of hard-coding an English word order.
 */
export function richText(
  template: string,
  values: Readonly<Record<string, ReactNode>>,
): ReactNode[] {
  const parts = template.split(/(\{\w+\})/gu);
  return parts.map((part, index) => {
    const match = /^\{(\w+)\}$/u.exec(part);
    if (!match) return part;
    const replacement = values[match[1]];
    return replacement === undefined
      ? part
      : <Fragment key={index}>{replacement}</Fragment>;
  });
}
