import { useTranslations, useLocale } from "next-intl";
import {
  JsonLd,
  articleSchema,
  breadcrumbList,
} from "@/app/[locale]/components/json-ld";

/**
 * Article + BreadcrumbList JSON-LD for a blog post. Defaults to the post's
 * localized title and metadata description; callers with audited SEO copy can
 * pass the exact headline and description shared by page metadata.
 */
export function BlogSchema({
  postKey,
  path,
  datePublished,
  headline: headlineOverride,
  description: descriptionOverride,
}: {
  postKey: string;
  path: string;
  datePublished: string;
  headline?: string;
  description?: string;
}) {
  const tp = useTranslations(`blog.posts.${postKey}`);
  const tm = useTranslations(`blog.${postKey}`);
  const tl = useTranslations("landing.links");
  const tn = useTranslations("nav");
  const locale = useLocale();

  const headline = headlineOverride ?? tp("title");
  const description = descriptionOverride ?? tm("metaDescription");

  return (
    <>
      <JsonLd
        data={articleSchema({
          locale,
          path,
          headline,
          description,
          datePublished,
        })}
      />
      <JsonLd
        data={breadcrumbList(locale, [
          { name: tl("home"), path: "/" },
          { name: tn("blog"), path: "/blog" },
          { name: headline, path },
        ])}
      />
    </>
  );
}
