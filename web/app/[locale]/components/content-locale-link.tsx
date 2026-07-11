import type { ComponentProps } from "react";
import NextLink from "next/link";
import { Link } from "../../../i18n/navigation";
import type { Locale } from "../../../i18n/routing";

type ContentLocaleLinkProps = Omit<ComponentProps<typeof NextLink>, "locale"> & {
  currentLocale: string;
  contentLocales?: readonly Locale[];
};

export function ContentLocaleLink({
  currentLocale,
  contentLocales,
  ...props
}: ContentLocaleLinkProps) {
  if (!contentLocales) {
    return <Link {...props} />;
  }

  const requestedLocale = currentLocale as Locale;
  const contentLocale = contentLocales.includes(requestedLocale)
    ? requestedLocale
    : contentLocales[0];

  if (contentLocale === "en") {
    return <NextLink {...props} />;
  }
  return <Link {...props} locale={contentLocale} />;
}
