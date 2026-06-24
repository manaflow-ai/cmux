import { useTranslations, useLocale } from "next-intl";
import { JsonLd, breadcrumbList } from "../components/json-ld";

/**
 * BreadcrumbList JSON-LD for a docs page: Home > Docs > <page>. The page name
 * is read from the page's `docs.<namespace>.title`.
 */
export function DocsSchema({
  namespace,
  path,
}: {
  namespace: string;
  path: string;
}) {
  const t = useTranslations(namespace);
  const tl = useTranslations("landing.links");
  const tn = useTranslations("nav");
  const locale = useLocale();

  return (
    <JsonLd
      data={breadcrumbList(locale, [
        { name: tl("home"), path: "/" },
        { name: tn("docs"), path: "/docs" },
        { name: t("title"), path },
      ])}
    />
  );
}
