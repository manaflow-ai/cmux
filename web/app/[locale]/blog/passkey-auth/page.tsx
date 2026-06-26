import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { buildAlternates } from "../../../../i18n/seo";
import { BlogSchema } from "../blog-schema";
import { Link } from "../../../../i18n/navigation";
import { CodeBlock } from "../../components/code-block";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "blog.passkeyAuth" });
  const rawKeywords = t.raw("metaKeywords");
  const keywords = Array.isArray(rawKeywords)
    ? rawKeywords.filter((keyword): keyword is string => typeof keyword === "string")
    : [];
  return {
    title: t("metaTitle"),
    description: t("metaDescription"),
    keywords,
    openGraph: {
      title: t("metaTitle"),
      description: t("metaDescription"),
      type: "article",
      publishedTime: "2026-05-22T00:00:00Z",
    },
    twitter: {
      card: "summary_large_image",
      title: t("metaTitle"),
      description: t("metaDescription"),
    },
    alternates: buildAlternates(locale, "/blog/passkey-auth"),
  };
}

export default function PasskeyAuthPage() {
  const t = useTranslations("blog.posts.passkeyAuth");
  const tc = useTranslations("common");

  return (
    <>
      <BlogSchema postKey="passkeyAuth" path="/blog/passkey-auth" datePublished="2026-05-22T00:00:00Z" />
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
