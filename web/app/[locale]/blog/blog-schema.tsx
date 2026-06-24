import { useTranslations, useLocale } from "next-intl";
import {
  JsonLd,
  articleSchema,
  breadcrumbList,
} from "../components/json-ld";

/**
 * Article + BreadcrumbList JSON-LD for a blog post. Reads the post title from
 * the post's `blog.posts.<key>` namespace and the description from the post's
 * `blog.<key>.metaDescription`. Breadcrumb is Home > Blog > <post>.
 */
export function BlogSchema({
  postKey,
  path,
  datePublished,
}: {
  postKey: string;
  path: string;
  datePublished: string;
}) {
  const tp = useTranslations(`blog.posts.${postKey}`);
  const tm = useTranslations(`blog.${postKey}`);
  const tl = useTranslations("landing.links");
  const tn = useTranslations("nav");
  const locale = useLocale();

  const headline = tp("title");
  const description = tm("metaDescription");

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
