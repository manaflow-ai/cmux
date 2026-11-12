import { useTranslations, useLocale } from "next-intl";
import { JsonLd, breadcrumbList } from "@/app/[locale]/components/json-ld";

/**
 * BreadcrumbList JSON-LD for a docs page: Home > Docs > <page>. The page name
 * is `title` when given (pages whose text is data, such as cmux-next's), else
 * the page's `docs.<namespace>.title`.
 */
export function DocsSchema({
  namespace = "docs",
  path,
  title,
}: {
  namespace?: string;
  path: string;
  title?: string;
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
        { name: title ?? t("title"), path },
      ])}
    />
  );
}
