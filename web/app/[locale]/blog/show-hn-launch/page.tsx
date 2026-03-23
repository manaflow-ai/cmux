import Image from "next/image";
import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { Link } from "../../../../i18n/navigation";
import { Tweet } from "react-tweet";
import starHistory from "./star-history.png";

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "blog.showHnLaunch" });
  const url = locale === "en" ? "/blog/show-hn-launch" : `/${locale}/blog/show-hn-launch`;
  return {
    title: t("metaTitle"),
    description: t("metaDescription"),
    keywords: [
      "cmux", "Show HN", "Hacker News", "terminal", "macOS", "Ghostty",
      "libghostty", "AI coding agents", "Claude Code", "Codex", "launch",
      "vertical tabs", "notification rings",
    ],
    openGraph: {
      title: t("metaTitle"),
      description: t("metaDescription"),
      type: "article",
      publishedTime: "2026-02-21T00:00:00Z",
      url,
    },
    twitter: {
      card: "summary_large_image",
      title: t("metaTitle"),
      description: t("metaDescription"),
    },
    alternates: { canonical: url },
  };
}

export default function ShowHNLaunchPage() {
  const t = useTranslations("blog.posts.showHnLaunch");
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
      <time dateTime="2026-02-21" className="text-sm text-muted">{t("date")}</time>

      <p className="mt-6">
        {t.rich("intro", {
          link: (chunks) => (
            <a href="https://news.ycombinator.com/item?id=47079718">{chunks}</a>
          ),
        })}
      </p>

      <blockquote className="border-l-2 border-border pl-4 my-6 text-muted space-y-3 text-[15px]">
        <p>{t("blockquote1")}</p>
        <p>{t("blockquote2")}</p>
        <p>{t("blockquote3")}</p>
        <p>{t("blockquote4")}</p>
        <p>{t("blockquote5")}</p>
      </blockquote>

      <p>{t("hitNumber2")}</p>

      <Tweet id="2024913161238053296" />

      <p>
        {t.rich("favoriteComment", {
          link: (chunks) => (
            <a href="https://news.ycombinator.com/item?id=47079718">{chunks}</a>
          ),
        })}
      </p>

      {/* Keep the HN comment blockquote in English as it's a direct quote */}
      <blockquote className="border-l-2 border-border pl-4 my-6 text-muted space-y-3 text-[15px]">
        <p>
          Hey, this looks seriously awesome. Love the ideas here, specifically:
          the programmability (I haven&apos;t tried it yet, but had been
          considering learning tmux partly for this), layered UI, browser w/
          api. Looking forward to giving this a spin. Also want to add that I
          really appreciate Mitchell Hashimoto creating libghostty; it feels
          like an exciting time to be a terminal user.
        </p>
        <p>Some feedback (since you were asking for it elsewhere in the thread!):</p>
        <ul className="list-disc pl-5 space-y-1">
          <li>
            It&apos;s not obvious/easy to open browser dev tools (cmd-alt-i
            didn&apos;t work), and when I did find it (right click page &rarr;
            inspect element) none of the controls were visible but I could see
            stuff happening when I moved my mouse over the panel
          </li>
          <li>
            Would be cool to borrow more of ghostty&apos;s behavior:
            <ul className="list-disc pl-5 mt-1 space-y-1">
              <li>hotkey overrides</li>
              <li>command palette (cmd-shift-p)</li>
              <li>cmd-z to &quot;zoom in&quot; to a pane</li>
            </ul>
          </li>
        </ul>
        <p className="text-xs">
          —{" "}
          <a href="https://news.ycombinator.com/item?id=47083596" className="hover:text-foreground transition-colors">
            johnthedebs
          </a>
        </p>
      </blockquote>

      <p>{t("viralJapan")}</p>

      <Tweet id="2025129675262251026" />

      <p>{t("translation")}</p>

      <p>{t("viralChina")}</p>

      <Tweet id="2024867449947275444" />

      <p>{t("extensions")}</p>

      <Tweet id="2024978414822916358" />

      <p>{t("scriptable")}</p>

      <p>
        {t.rich("cta", {
          link: (chunks) => (
            <a href="https://github.com/manaflow-ai/cmux">{chunks}</a>
          ),
        })}
      </p>

      <div className="my-6">
        <Image
          src={starHistory}
          alt="cmux GitHub star history showing growth from near 0 to 900+ stars after the Show HN launch"
          placeholder="blur"
          className="w-full rounded-xl"
        />
      </div>
    </>
  );
}
