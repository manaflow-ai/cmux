import type { Metadata } from "next";
import { useTranslations } from "next-intl";
import { Link } from "../../../../i18n/navigation";

export const metadata: Metadata = {
  title: "Cmd+Shift+U",
  description:
    "How Cmd+Shift+U navigates between finished agents across workspaces in cmux.",
  keywords: [
    "cmux", "terminal", "macOS", "notifications", "AI coding agents",
    "keyboard shortcuts", "developer tools", "workflow",
  ],
  openGraph: {
    title: "Cmd+Shift+U",
    description:
      "How Cmd+Shift+U navigates between finished agents across workspaces in cmux.",
    type: "article",
    publishedTime: "2026-03-04T00:00:00Z",
    url: "https://cmux.dev/blog/cmd-shift-u",
  },
  twitter: {
    card: "summary",
    title: "Cmd+Shift+U",
    description:
      "How Cmd+Shift+U navigates between finished agents across workspaces in cmux.",
  },
  alternates: { canonical: "https://cmux.dev/blog/cmd-shift-u" },
};

export default function CmdShiftUPage() {
  const t = useTranslations("blog.posts.cmdShiftU");
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
      <time dateTime="2026-03-04" className="text-sm text-muted">
        {t("date")}
      </time>

      <p className="mt-6">{t("p1")}</p>

      <video
        src="/blog/cmd-shift-u.mp4"
        width={1824}
        height={1080}
        autoPlay
        loop
        muted
        playsInline
        className="my-6 rounded-lg w-full h-auto"
      />

      <p>
        {t.rich("p2", {
          link: (chunks) => (
            <Link href="/docs/notifications">{chunks}</Link>
          ),
        })}
      </p>
    </>
  );
}
