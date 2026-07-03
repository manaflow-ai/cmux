import { getTranslations } from "next-intl/server";
import { hasFeatureWorkflowContent } from "../../../../i18n/locale-availability";
import { buildAlternates } from "../../../../i18n/seo";
import { BlogSchema } from "../blog-schema";
import { Link } from "../../../../i18n/navigation";

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "blog.cmuxSsh" });
  return {
    title: t("metaTitle"),
    description: t("metaDescription"),
    keywords: [
      "cmux", "SSH", "remote development", "terminal", "macOS",
      "port forwarding", "notifications", "AI coding agents",
      "Claude Code", "remote workspace", "developer tools",
    ],
    openGraph: {
      title: t("metaTitle"),
      description: t("metaDescription"),
      type: "article",
      publishedTime: "2026-03-30T00:00:00Z",
      modifiedTime: "2026-07-03T00:00:00Z",
    },
    twitter: {
      card: "summary_large_image",
      title: t("metaTitle"),
      description: t("metaDescription"),
    },
    alternates: buildAlternates(locale, "/blog/cmux-ssh"),
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
      <time dateTime="2026-03-30" className="text-sm text-muted">
        {t("date")}
      </time>

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

          <h2>{t("featureTitle")}</h2>
          <ul className="mt-4 space-y-1">
            <li>{t.rich("featureBrowser", { code: (chunks) => <code>{chunks}</code> })}</li>
            <li>{t("featureUpload")}</li>
            <li>{t("featureNotify")}</li>
            <li>{t.rich("featureAgents", { code: (chunks) => <code>{chunks}</code> })}</li>
            <li>{t("featureSidebar")}</li>
          </ul>
        </>
      ) : null}

      <iframe
        className="my-6 rounded-lg w-full aspect-video"
        src="https://www.youtube.com/embed/RoR9pMOZWkk"
        title="cmux SSH demo"
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

          <p className="mt-6">
            {t.rich("docsCta", {
              link: (chunks) => <Link href="/docs/ssh">{chunks}</Link>,
            })}
          </p>
        </>
      ) : null}
    </>
  );
}
