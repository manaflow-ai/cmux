import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { buildAlternates, openGraphDefaults, twitterSummary } from "@/i18n/seo";
import { blogPostSeoCopy } from "@/i18n/audited-seo";
import { BlogSchema } from "../blog-schema";
import { Link } from "@/i18n/navigation";
import { CodeBlock } from "@/app/[locale]/components/code-block";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "blog.passkeyAuth" });
  const post = await getTranslations({ locale, namespace: "blog.posts.passkeyAuth" });
  const siteMeta = await getTranslations({ locale, namespace: "meta" });
  const rawKeywords = t.raw("metaKeywords");
  const keywords = Array.isArray(rawKeywords)
    ? rawKeywords.filter((keyword): keyword is string => typeof keyword === "string")
    : [];
  const alternates = buildAlternates(locale, "/blog/passkey-auth");
  const { title, description } = blogPostSeoCopy(locale, "passkeyAuth", t, post, siteMeta);
  return {
    title: { absolute: title },
    description,
    keywords,
    openGraph: {
      ...openGraphDefaults(locale, "article"),
      title,
      description,
      url: alternates.canonical,
      publishedTime: "2026-05-22T00:00:00Z",
    },
    twitter: twitterSummary(locale, title, description),
    alternates,
  };
}

export default function PasskeyAuthPage() {
  const t = useTranslations("blog.posts.passkeyAuth");
  const tc = useTranslations("common");

  return (
    <>
      <BlogSchema postKey="passkeyAuth" seoKey="passkeyAuth" path="/blog/passkey-auth" datePublished="2026-05-22T00:00:00Z" />
      <div className="mb-8">
        <Link
          href="/blog"
          className="text-sm text-muted hover:text-foreground transition-colors"
        >
          &larr; {tc("backToBlog")}
        </Link>
      </div>

      <h1>{t("title")}</h1>
      <time dateTime="2026-05-22" className="text-sm text-muted">
        {t("date")}
      </time>

      <video
        src="/blog/passkey-browser-import.mp4"
        width={1280}
        height={988}
        autoPlay
        loop
        muted
        playsInline
        className="my-6 rounded-lg w-full h-auto"
      />

      <p className="mt-6">{t("p1")}</p>
      <p>{t("p2")}</p>
      <CodeBlock lang="bash">{`cmux browser import`}</CodeBlock>
      <p>{t("p3")}</p>
    </>
  );
}
