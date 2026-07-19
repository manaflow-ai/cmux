import { getTranslations } from "next-intl/server";
import {
  fallbackContentLocales,
  hasFeatureWorkflowContent,
} from "@/i18n/locale-availability";
import { buildAlternates, openGraphDefaults, seoDescription, twitterSummary } from "@/i18n/seo";
import { BlogSchema } from "../blog-schema";
import { Link } from "@/i18n/navigation";

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
        </>
      ) : null}

      <ul className="mt-4 space-y-1">
        <li>Browser panes route through the remote machine, so <code>localhost:3000</code> reaches the remote dev server without port forwarding</li>
        <li>Drag an image into a remote terminal to upload via scp</li>
        <li>Coding agents on the remote box send notifications to your local sidebar</li>
        <li><code>cmux claude-teams</code> and <code>cmux omo</code> work over SSH, spawning teammate panes locally while computation runs remote</li>
        <li>The sidebar shows connection state and detected listening ports</li>
      </ul>

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
        </>
      ) : null}

      <p className="mt-4">
        <Link href="/docs/ssh">Read the SSH docs &rarr;</Link>
      </p>
    </>
  );
}
