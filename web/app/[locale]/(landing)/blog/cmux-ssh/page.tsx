import { getTranslations } from "next-intl/server";
import {
  fallbackContentLocales,
  hasFeatureWorkflowContent,
} from "@/i18n/locale-availability";
import { buildAlternates, openGraphDefaults, seoDescription, twitterSummary } from "@/i18n/seo";
import { BlogSchema } from "../blog-schema";
import { Link } from "@/i18n/navigation";
import { BlogPostMeta } from "@/app/[locale]/components/blog-author";

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "blog.cmuxSsh" });
  const alternates = buildAlternates(
    locale,
    "/blog/cmux-ssh",
    fallbackContentLocales,
  );
  const title = t("metaTitle");
  const description = seoDescription(locale, t("metaDescription"));
  return {
    title,
    description,
    openGraph: {
      ...openGraphDefaults(locale, "article"),
      title,
      description,
      url: alternates.canonical,
      publishedTime: "2026-03-30T00:00:00Z",
      modifiedTime: "2026-07-03T00:00:00Z",
    },
    twitter: twitterSummary(locale, title, description),
    alternates,
  };
}

export default async function CmuxSshPage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const showFeatureWorkflow = hasFeatureWorkflowContent(locale);
  const t = await getTranslations({ locale, namespace: "blog.posts.cmuxSsh" });
  const tc = await getTranslations({ locale, namespace: "common" });
  const featureItems = t.raw("featureItems") as string[];

  return (
    <>
      <BlogSchema postKey="cmuxSsh" path="/blog/cmux-ssh" datePublished="2026-03-30T00:00:00Z" />
      <div className="mb-8">
        <Link
          href="/blog"
          className="text-sm text-muted hover:text-foreground transition-colors"
        >
          &larr; {tc("backToBlog")}
        </Link>
      </div>

      <h1>{t("title")}</h1>
      <BlogPostMeta date={t("date")} dateTime="2026-03-30" />

      <p className="mt-6">
        {t.rich("p1", {
          code: (chunks) => <code>{chunks}</code>,
        })}
      </p>

      <video
        src="/blog/cmux-ssh-image-upload.mp4"
        width={1824}
        height={1080}
        autoPlay
        loop
        muted
        playsInline
        className="my-6 rounded-lg w-full h-auto"
      />

      {showFeatureWorkflow ? (
        <>
          <h2>{t("workflowTitle")}</h2>
          <ol>
            <li>{t("workflowConnect")}</li>
            <li>{t("workflowPreview")}</li>
            <li>{t("workflowNotify")}</li>
            <li>{t("workflowUpload")}</li>
          </ol>
        </>
      ) : null}

      <ul className="mt-4 space-y-1">
        {featureItems.map((item, index) => (
          <li key={index}>{item}</li>
        ))}
      </ul>

      <iframe
        className="my-6 rounded-lg w-full aspect-video"
        src="https://www.youtube.com/embed/RoR9pMOZWkk"
        title={t("videoTitle")}
        allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture"
        allowFullScreen
      />

      {showFeatureWorkflow ? (
        <>
          <h2>{t("faqTitle")}</h2>
          <h3>{t("faqPortTitle")}</h3>
          <p>{t("faqPortBody")}</p>
          <h3>{t("faqConfigTitle")}</h3>
          <p>{t("faqConfigBody")}</p>
        </>
      ) : null}

      <p className="mt-4">
        <Link href="/docs/ssh">{t("readDocs")} &rarr;</Link>
      </p>
    </>
  );
}
