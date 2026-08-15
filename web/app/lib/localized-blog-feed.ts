import { createTranslator } from "use-intl/core";
import {
  blogPostsForLocale,
  type BlogPost,
} from "../[locale]/components/blog-posts";
import { routing, type Locale } from "../../i18n/routing";
import { loadMessages } from "../../i18n/messages";
import { buildBlogRssFeed } from "./blog-feed";

const siteUrl = "https://cmux.com";

export async function buildLocalizedBlogRssFeed(locale: Locale): Promise<string> {
  const t = createTranslator({
    locale,
    messages: await loadMessages(locale),
    namespace: "blog",
  });
  const localePrefix = locale === routing.defaultLocale ? "" : `/${locale}`;
  const blogUrl = `${siteUrl}${localePrefix}/blog`;
  const feedUrl = `${siteUrl}${localePrefix}/feed.xml`;
  const posts: BlogPost[] = blogPostsForLocale(locale).map((post) => ({
    ...post,
    title: t(`posts.${post.key}.title`),
    summary: t(`posts.${post.key}.summary`),
  }));

  return buildBlogRssFeed(posts, {
    blogUrl,
    description: t("metaDescription"),
    feedUrl,
    language: locale,
    title: t("layoutTitle"),
  });
}
