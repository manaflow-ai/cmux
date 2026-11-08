import type { ComponentProps } from "react";
import NextLink from "next/link";
import { Link } from "../../../i18n/navigation";
import type { Locale } from "../../../i18n/routing";

type SharedLinkProps = Omit<
  ComponentProps<typeof NextLink>,
  "href" | "locale"
> & {
  currentLocale: string;
};

type ContentLocaleLinkProps = SharedLinkProps &
  (
    | {
        contentLocales: readonly Locale[];
        href: string;
      }
    | {
        contentLocales?: undefined;
        href: ComponentProps<typeof NextLink>["href"];
      }
  );

export function ContentLocaleLink(props: ContentLocaleLinkProps) {
  if (!props.contentLocales) {
    const {
      currentLocale: omittedCurrentLocale,
      contentLocales: omittedContentLocales,
      ...linkProps
    } = props;
    void omittedCurrentLocale;
    void omittedContentLocales;
    return <Link {...linkProps} />;
  }

  const { currentLocale, contentLocales, href, ...linkProps } = props;
  const requestedLocale = currentLocale as Locale;
  const contentLocale = contentLocales.includes(requestedLocale)
    ? requestedLocale
    : contentLocales[0];
  const localizedHref = localizeContentHref(href, contentLocale);

  return <NextLink {...linkProps} href={localizedHref} />;
}

function localizeContentHref(href: string, locale: Locale): string {
  if (locale === "en" || !href.startsWith("/")) {
    return href;
  }
  return `/${locale}${href === "/" ? "" : href}`;
}
