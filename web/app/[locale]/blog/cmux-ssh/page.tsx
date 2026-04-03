import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { buildAlternates } from "../../../../i18n/seo";
import { Link } from "../../../../i18n/navigation";
import { CodeBlock } from "../../components/code-block";

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
    },
    twitter: {
      card: "summary_large_image",
      title: t("metaTitle"),
      description: t("metaDescription"),
    },
    alternates: buildAlternates(locale, "/blog/cmux-ssh"),
  };
}

export default function CmuxSshPage() {
  const t = useTranslations("blog.posts.cmuxSsh");
  const tc = useTranslations("common");

  return (
    <>
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

      <ul className="mt-4 space-y-1">
        <li>Browser panes route through the remote machine, so <code>localhost:3000</code> reaches the remote dev server without port forwarding</li>
        <li>Drag an image into a remote terminal to upload via scp</li>
        <li>Coding agents on the remote box send notifications to your local sidebar</li>
        <li><code>cmux claude-teams</code> and <code>cmux omo</code> work over SSH, spawning teammate panes locally while computation runs remote</li>
        <li>The sidebar shows connection state and detected listening ports</li>
      </ul>

      <h2 className="mt-10">SSH Sandboxes</h2>
      <p className="mt-4">
        The new SSH sandbox mode keeps the same remote workspace UX, but starts the shell
        inside Docker Sandboxes on the remote host. That gives you the browser proxying,
        notifications, and reconnect flow from <code>cmux ssh</code>, while moving the
        actual shell into an isolated Docker sandbox.
      </p>

      <CodeBlock lang="bash">{`cmux ssh dev@macmini --docker-sandbox --docker-sandbox-workspace ~/src/cmux
cmux ssh dev@macmini --docker-sandbox --docker-sandbox-name cmux-dev
cmux ssh dev@macmini --docker-sandbox --docker-sandbox-workspace ~/src/cmux --docker-sandbox-mount ~/docs/cmux:ro`}</CodeBlock>

      <p className="mt-4">
        This is built for Docker Desktop&apos;s <code>docker sandbox</code> integration on
        the remote machine. cmux checks for that command before the workspace finishes
        connecting, creates missing writable workspace directories, and then runs
        <code>docker sandbox run shell</code> for you.
      </p>

      <iframe
        className="my-6 rounded-lg w-full aspect-video"
        src="https://www.youtube.com/embed/RoR9pMOZWkk"
        title="cmux SSH demo"
        allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture"
        allowFullScreen
      />

      <p className="mt-4">
        <Link href="/docs/ssh">Read the SSH docs &rarr;</Link>
      </p>
    </>
  );
}
