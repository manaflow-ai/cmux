import Image from "next/image";
import { useLocale, useTranslations } from "next-intl";
import { getLocale, getTranslations } from "next-intl/server";
import { Link } from "@/i18n/navigation";
import { SiteHeader } from "@/app/[locale]/components/site-header";
import { BrandLogoLink } from "@/app/[locale]/components/brand-logo-link";
import { DownloadButton } from "@/app/[locale]/components/download-button";
import { GitHubButton } from "@/app/[locale]/components/github-button";
import { CopyPrompt } from "@/app/[locale]/components/copy-prompt";
import { breadcrumbList } from "@/app/[locale]/components/json-ld-data";
import { JsonLd } from "@/app/[locale]/components/json-ld";
import { buildAlternates, openGraphDefaults, twitterSummary } from "@/i18n/seo";
import { codingAgents } from "@/i18n/coding-agents";

// The homepage's terminal-compatible agents, with Pi requested for this page.
const agentSlugs = ["claude-code", "codex", "opencode", "pi", "gemini-cli", "kiro", "aider", "goose", "amp", "cline", "cursor-cli"];
const agentNames = agentSlugs.map((slug) => {
  const agent = codingAgents.find((item) => item.slug === slug)!;
  return slug === "cursor-cli" ? "Cursor Agent" : agent.name;
});
const linkClass = "text-sm text-muted underline underline-offset-2 decoration-link-underline hover:text-foreground hover:decoration-foreground transition-colors";

function ComputerUseActions({ location }: { location: string }) {
  const common = useTranslations("common");
  return (
    <div className="flex flex-wrap items-center gap-3" data-dev="cua-action-row">
      <DownloadButton location={location} />
      <GitHubButton location={location} />
      <Link href="/docs/computer-use" className={linkClass}>{common("readTheDocs")}</Link>
    </div>
  );
}

export async function generateMetadata() {
  const locale = await getLocale();
  const t = await getTranslations({ locale, namespace: "docs.computerUse" });
  const alternates = buildAlternates(locale, "/cua");
  const title = t("metaTitle");
  const description = t("metaDescription");
  return {
    title, description, alternates,
    openGraph: { ...openGraphDefaults(locale, "website"), title, description, url: alternates.canonical },
    twitter: twitterSummary(locale, title, description),
  };
}

export default function ComputerUsePage() {
  const t = useTranslations("docs.computerUse");
  const common = useTranslations("common");
  const links = useTranslations("landing.links");
  const locale = useLocale();
  const agents = new Intl.ListFormat(locale, { type: "unit" }).format(agentNames);
  return (
    <>
      <SiteHeader hideLogo />
      <main className="w-full max-w-2xl mx-auto px-6 py-16 sm:py-24">
        <JsonLd data={breadcrumbList(locale, [{ name: links("home"), path: "/" }, { name: t("title"), path: "/cua" }])} />
        <div className="flex items-center gap-4 mb-10" data-dev="cua-header">
          <BrandLogoLink className="shrink-0">
            <Image src="/logo.png" alt="cmux" width={48} height={48} className="rounded-xl" />
          </BrandLogoLink>
          <h1 className="text-2xl font-semibold tracking-tight">{t("title")}</h1>
        </div>
        <p className="text-lg leading-relaxed mb-3 text-foreground">{t("tagline")}</p>
        <p className="text-base text-muted leading-normal">{t("intro")}</p>
        <div className="mt-[21px] mb-4" data-dev="cua-cta">
          <ComputerUseActions location="landing" />
        </div>
        <figure className="my-12">
          <Image
            src="/cua-permissions.png" alt={t("imageAlt")}
            width={1200} height={880} preload
            sizes="(max-width: 672px) calc(100vw - 48px), 624px"
            className="w-full h-auto rounded-xl"
          />
          <figcaption className="mt-3 text-center text-xs text-muted">{t("caption")}</figcaption>
        </figure>
        <section className="mb-10 text-[15px] leading-normal">
          <h2 className="text-xs font-medium text-muted tracking-tight mb-3">{t("featuresTitle")}</h2>
          <ul className="space-y-3">
            {["featureInspect", "featureAct", "featureReview"].map((key) => (
              <li key={key} className="flex gap-3"><span className="text-muted shrink-0" aria-hidden="true">-</span><span>{t(key)}</span></li>
            ))}
          </ul>
        </section>
        <section className="mb-10 text-[15px] leading-normal">
          <h2 className="text-xs font-medium text-muted tracking-tight mb-3">{t("agentsTitle")}</h2>
          <p className="text-muted">{t("agentsBody", { agents })}</p>
          <p className="mt-3 text-muted">{t("supportBody")}</p>
        </section>
        <section className="mb-10 text-[15px] leading-normal">
          <h2 className="text-xs font-medium text-muted tracking-tight mb-3">{t("setupTitle")}</h2>
          <ol className="list-decimal ps-5 space-y-3 text-muted">
            <li>{t("step1")}</li><li>{t("step2")}</li><li>{t("step3")}</li>
          </ol>
        </section>
        <section className="mb-10 text-[15px] leading-normal">
          <h2 className="text-xs font-medium text-muted tracking-tight mb-3">{t("copyTitle")}</h2>
          <CopyPrompt
            prompt={t("installPrompt")}
            copyLabel={t("copyPrompt")}
            copiedLabel={t("copiedPrompt")}
          />
        </section>
        <div className="border-t border-border pt-[21px]" data-dev="cua-footer-links">
          <ComputerUseActions location="landing-footer" />
          <div className="mt-6">
            <Link href="/docs/changelog" className={linkClass}>{common("viewChangelog")}</Link>
          </div>
        </div>
      </main>
    </>
  );
}
