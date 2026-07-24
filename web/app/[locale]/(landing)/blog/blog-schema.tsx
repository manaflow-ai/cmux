import { useTranslations, useLocale } from "next-intl";
import {
  JsonLd,
  articleSchema,
  breadcrumbList,
} from "@/app/[locale]/components/json-ld";
import {
  type AuditedBlogPostKey,
  blogPostSeoCopy,
} from "@/i18n/audited-seo";

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
  seoKey,
}: {
  postKey: string;
  path: string;
  datePublished: string;
  headline?: string;
  description?: string;
  seoKey?: AuditedBlogPostKey;
}) {
  const tp = useTranslations(`blog.posts.${postKey}`);
  const tm = useTranslations(`blog.${postKey}`);
  const tl = useTranslations("landing.links");
  const tn = useTranslations("nav");
  const siteMeta = useTranslations("meta");
  const locale = useLocale();

  const auditedCopy = seoKey
    ? blogPostSeoCopy(locale, seoKey, tm, tp, siteMeta)
    : undefined;
  const headline = headlineOverride ?? auditedCopy?.title ?? tp("title");
  const description =
    descriptionOverride ?? auditedCopy?.description ?? tm("metaDescription");

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
