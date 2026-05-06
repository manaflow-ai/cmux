import Image from "next/image";
import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { buildAlternates } from "../../../i18n/seo";
import { SiteHeader } from "../components/site-header";
import { AutoDownload } from "./auto-download";

const DMG_URL =
  "https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg";
const RELEASES_URL = "https://github.com/manaflow-ai/cmux/releases/latest";
const DISCORD_URL = "https://discord.gg/xsgFEVrWCZ";
const GITHUB_URL = "https://github.com/manaflow-ai/cmux";
const TWITTER_URL = "https://twitter.com/manaflowai";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "thanks" });
  return {
    title: t("metaTitle"),
    description: t("metaDescription"),
    alternates: buildAlternates(locale, "/thanks"),
    robots: { index: false, follow: true },
  };
}

function Step({
  n,
  title,
  imageSrc,
  imageAlt,
}: {
  n: number;
  title: string;
  imageSrc: string;
  imageAlt: string;
}) {
  return (
    <div className="rounded-2xl border border-border bg-code-bg/40 p-5 flex flex-col items-center text-center">
      <div className="size-7 rounded-full bg-foreground text-background text-xs font-semibold flex items-center justify-center mb-4">
        {n}
      </div>
      <div className="w-full aspect-[11/7] flex items-center justify-center mb-4">
        <Image
          src={imageSrc}
          alt={imageAlt}
          width={880}
          height={560}
          className="w-full h-full object-contain"
          priority={n === 1}
        />
      </div>
      <p className="text-[15px] leading-snug">{title}</p>
    </div>
  );
}

function DiscordIcon() {
  return (
    <svg width="20" height="20" viewBox="0 0 24 24" fill="currentColor">
      <path d="M20.317 4.37a19.791 19.791 0 0 0-4.885-1.515.074.074 0 0 0-.079.037c-.21.375-.444.864-.608 1.25a18.27 18.27 0 0 0-5.487 0 12.64 12.64 0 0 0-.617-1.25.077.077 0 0 0-.079-.037A19.736 19.736 0 0 0 3.677 4.37a.07.07 0 0 0-.032.027C.533 9.046-.32 13.58.099 18.057a.082.082 0 0 0 .031.057 19.9 19.9 0 0 0 5.993 3.03.078.078 0 0 0 .084-.028c.462-.63.874-1.295 1.226-1.994a.076.076 0 0 0-.041-.106 13.107 13.107 0 0 1-1.872-.892.077.077 0 0 1-.008-.128 10.2 10.2 0 0 0 .372-.292.074.074 0 0 1 .077-.01c3.928 1.793 8.18 1.793 12.062 0a.074.074 0 0 1 .078.01c.12.098.246.198.373.292a.077.077 0 0 1-.006.127 12.299 12.299 0 0 1-1.873.892.077.077 0 0 0-.041.107c.36.698.772 1.362 1.225 1.993a.076.076 0 0 0 .084.028 19.839 19.839 0 0 0 6.002-3.03.077.077 0 0 0 .032-.054c.5-5.177-.838-9.674-3.549-13.66a.061.061 0 0 0-.031-.03zM8.02 15.33c-1.183 0-2.157-1.085-2.157-2.419 0-1.333.956-2.419 2.157-2.419 1.21 0 2.176 1.096 2.157 2.42 0 1.333-.956 2.418-2.157 2.418zm7.975 0c-1.183 0-2.157-1.085-2.157-2.419 0-1.333.955-2.419 2.157-2.419 1.21 0 2.176 1.096 2.157 2.42 0 1.333-.946 2.418-2.157 2.418z" />
    </svg>
  );
}

function GitHubIcon() {
  return (
    <svg width="20" height="20" viewBox="0 0 24 24" fill="currentColor">
      <path d="M12 0c-6.626 0-12 5.373-12 12 0 5.302 3.438 9.8 8.207 11.387.599.111.793-.261.793-.577v-2.234c-3.338.726-4.033-1.416-4.033-1.416-.546-1.387-1.333-1.756-1.333-1.756-1.089-.745.083-.729.083-.729 1.205.084 1.839 1.237 1.839 1.237 1.07 1.834 2.807 1.304 3.492.997.107-.775.418-1.305.762-1.604-2.665-.305-5.467-1.334-5.467-5.931 0-1.311.469-2.381 1.236-3.221-.124-.303-.535-1.524.117-3.176 0 0 1.008-.322 3.301 1.23.957-.266 1.983-.399 3.003-.404 1.02.005 2.047.138 3.006.404 2.291-1.552 3.297-1.23 3.297-1.23.653 1.653.242 2.874.118 3.176.77.84 1.235 1.911 1.235 3.221 0 4.609-2.807 5.624-5.479 5.921.43.372.823 1.102.823 2.222v3.293c0 .319.192.694.801.576 4.765-1.589 8.199-6.086 8.199-11.386 0-6.627-5.373-12-12-12z" />
    </svg>
  );
}

function TwitterIcon() {
  return (
    <svg width="20" height="20" viewBox="0 0 24 24" fill="currentColor">
      <path d="M18.244 2.25h3.308l-7.227 8.26 8.502 11.24H16.17l-5.214-6.817L4.99 21.75H1.68l7.73-8.835L1.254 2.25H8.08l4.713 6.231zm-1.161 17.52h1.833L7.084 4.126H5.117z" />
    </svg>
  );
}

export default function ThanksPage() {
  const t = useTranslations("thanks");

  return (
    <div className="min-h-screen">
      <SiteHeader />
      <AutoDownload url={DMG_URL} />

      <main className="w-full max-w-5xl mx-auto px-6 py-12 sm:py-16">
        <div className="rounded-xl border border-border bg-code-bg/60 px-4 py-3 text-sm flex flex-col sm:flex-row sm:items-center sm:justify-between gap-2 mb-12">
          <p className="text-muted">
            {t("downloadStarted")}{" "}
            <a
              href={DMG_URL}
              className="underline underline-offset-2 decoration-border hover:decoration-foreground transition-colors text-foreground"
            >
              {t("tryAgain")}
            </a>
          </p>
          <a
            href={RELEASES_URL}
            target="_blank"
            rel="noopener noreferrer"
            className="text-foreground/70 hover:text-foreground text-xs underline underline-offset-2 decoration-border hover:decoration-foreground transition-colors"
          >
            {t("otherDownloads")}
          </a>
        </div>

        <h1 className="text-3xl sm:text-4xl font-semibold tracking-tight text-center mb-3">
          {t("title")}
        </h1>
        <p className="text-muted text-center text-[15px] mb-12">
          {t("subtitle")}
        </p>

        <div className="grid gap-4 sm:grid-cols-3 mb-16">
          <Step
            n={1}
            title={t("step1")}
            imageSrc="/thanks/step1.png"
            imageAlt={t("step1Alt")}
          />
          <Step
            n={2}
            title={t("step2")}
            imageSrc="/thanks/step2.png"
            imageAlt={t("step2Alt")}
          />
          <Step
            n={3}
            title={t("step3")}
            imageSrc="/thanks/step3.png"
            imageAlt={t("step3Alt")}
          />
        </div>

        <section className="rounded-2xl border border-border p-6 sm:p-8 mb-12">
          <h2 className="text-xl font-semibold tracking-tight mb-2">
            {t("helpTitle")}
          </h2>
          <p className="text-muted text-[15px] mb-5">
            {t("helpDescription")}
          </p>
          <div className="flex flex-wrap gap-3">
            <a
              href={DISCORD_URL}
              target="_blank"
              rel="noopener noreferrer"
              className="inline-flex items-center gap-2 rounded-full bg-foreground px-4 py-2 text-[14px] font-medium hover:opacity-85 transition-opacity"
              style={{
                color: "var(--background)",
                textDecoration: "none",
              }}
            >
              <DiscordIcon />
              {t("joinDiscord")}
            </a>
            <a
              href={`${GITHUB_URL}/issues/new`}
              target="_blank"
              rel="noopener noreferrer"
              className="inline-flex items-center gap-2 rounded-full border border-border px-4 py-2 text-[14px] font-medium hover:bg-code-bg transition-colors"
            >
              <GitHubIcon />
              {t("reportIssue")}
            </a>
          </div>
        </section>

        <section>
          <h2 className="text-xs font-medium text-muted tracking-tight mb-3 uppercase">
            {t("communityHeading")}
          </h2>
          <div className="grid gap-3 sm:grid-cols-3">
            <a
              href={DISCORD_URL}
              target="_blank"
              rel="noopener noreferrer"
              className="group flex items-center gap-3 rounded-xl border border-border px-4 py-3 hover:bg-code-bg transition-colors"
            >
              <span className="text-muted group-hover:text-foreground transition-colors">
                <DiscordIcon />
              </span>
              <span className="text-[14px] font-medium">{t("discord")}</span>
            </a>
            <a
              href={GITHUB_URL}
              target="_blank"
              rel="noopener noreferrer"
              className="group flex items-center gap-3 rounded-xl border border-border px-4 py-3 hover:bg-code-bg transition-colors"
            >
              <span className="text-muted group-hover:text-foreground transition-colors">
                <GitHubIcon />
              </span>
              <span className="text-[14px] font-medium">{t("github")}</span>
            </a>
            <a
              href={TWITTER_URL}
              target="_blank"
              rel="noopener noreferrer"
              className="group flex items-center gap-3 rounded-xl border border-border px-4 py-3 hover:bg-code-bg transition-colors"
            >
              <span className="text-muted group-hover:text-foreground transition-colors">
                <TwitterIcon />
              </span>
              <span className="text-[14px] font-medium">{t("twitter")}</span>
            </a>
          </div>
        </section>
      </main>
    </div>
  );
}
