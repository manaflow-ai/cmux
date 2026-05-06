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
    <svg width="24" height="24" viewBox="0 0 24 24" fill="currentColor">
      <path d="M18.244 2.25h3.308l-7.227 8.26 8.502 11.24H16.17l-5.214-6.817L4.99 21.75H1.68l7.73-8.835L1.254 2.25H8.08l4.713 6.231zm-1.161 17.52h1.833L7.084 4.126H5.117z" />
    </svg>
  );
}

function YouTubeIcon() {
  return (
    <svg width="24" height="24" viewBox="0 0 24 24" fill="currentColor">
      <path d="M23.498 6.186a3.016 3.016 0 0 0-2.122-2.136C19.505 3.545 12 3.545 12 3.545s-7.505 0-9.377.505A3.017 3.017 0 0 0 .502 6.186C0 8.07 0 12 0 12s0 3.93.502 5.814a3.016 3.016 0 0 0 2.122 2.136c1.871.505 9.376.505 9.376.505s7.505 0 9.377-.505a3.015 3.015 0 0 0 2.122-2.136C24 15.93 24 12 24 12s0-3.93-.502-5.814zM9.545 15.568V8.432L15.818 12l-6.273 3.568z" />
    </svg>
  );
}

function LinkedInIcon() {
  return (
    <svg width="24" height="24" viewBox="0 0 24 24" fill="currentColor">
      <path d="M20.447 20.452h-3.554v-5.569c0-1.328-.027-3.037-1.852-3.037-1.853 0-2.136 1.445-2.136 2.939v5.667H9.351V9h3.414v1.561h.046c.477-.9 1.637-1.85 3.37-1.85 3.601 0 4.267 2.37 4.267 5.455v6.286zM5.337 7.433c-1.144 0-2.063-.926-2.063-2.065 0-1.138.92-2.063 2.063-2.063 1.14 0 2.064.925 2.064 2.063 0 1.139-.925 2.065-2.064 2.065zm1.782 13.019H3.555V9h3.564v11.452zM22.225 0H1.771C.792 0 0 .774 0 1.729v20.542C0 23.227.792 24 1.771 24h20.451C23.2 24 24 23.227 24 22.271V1.729C24 .774 23.2 0 22.222 0h.003z" />
    </svg>
  );
}

function CommunityCard({
  href,
  icon,
  name,
  action,
  description,
}: {
  href: string;
  icon: React.ReactNode;
  name: string;
  action: string;
  description: string;
}) {
  return (
    <a
      href={href}
      target="_blank"
      rel="noopener noreferrer"
      className="group flex items-start gap-4 rounded-xl border border-border p-5 hover:bg-code-bg transition-colors"
    >
      <div className="shrink-0 mt-0.5 text-muted group-hover:text-foreground transition-colors">
        {icon}
      </div>
      <div className="min-w-0">
        <div className="font-medium text-[15px]">{name}</div>
        <div className="text-sm text-muted mt-0.5">{description}</div>
        <div className="text-xs font-medium text-muted mt-2 group-hover:text-foreground transition-colors">
          {action} &rarr;
        </div>
      </div>
    </a>
  );
}

export default function ThanksPage() {
  const t = useTranslations("thanks");
  const tc = useTranslations("community");

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
            imageSrc="/install/step1.png"
            imageAlt={t("step1Alt")}
          />
          <Step
            n={2}
            title={t("step2")}
            imageSrc="/install/step2.png"
            imageAlt={t("step2Alt")}
          />
          <Step
            n={3}
            title={t("step3")}
            imageSrc="/install/step3.png"
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
          <h2 className="text-xl font-semibold tracking-tight mb-2">
            {tc("title")}
          </h2>
          <p className="text-muted text-[15px] mb-6">{tc("description")}</p>
          <div className="grid gap-4 sm:grid-cols-2">
            <CommunityCard
              href={DISCORD_URL}
              icon={<DiscordIcon />}
              name={tc("discord")}
              action={tc("discordAction")}
              description={tc("discordDesc")}
            />
            <CommunityCard
              href={GITHUB_URL}
              icon={<GitHubIcon />}
              name="GitHub"
              action={tc("githubAction")}
              description={tc("githubDesc")}
            />
            <CommunityCard
              href={TWITTER_URL}
              icon={<TwitterIcon />}
              name={tc("twitter")}
              action={tc("twitterAction")}
              description={tc("twitterDesc")}
            />
            <CommunityCard
              href="https://www.youtube.com/channel/UCAa89_j-TWkrXfk9A3CbASw"
              icon={<YouTubeIcon />}
              name={tc("youtube")}
              action={tc("youtubeAction")}
              description={tc("youtubeDesc")}
            />
            <CommunityCard
              href="https://www.linkedin.com/company/manaflow-ai/"
              icon={<LinkedInIcon />}
              name={tc("linkedin")}
              action={tc("linkedinAction")}
              description={tc("linkedinDesc")}
            />
          </div>
        </section>
      </main>
    </div>
  );
}
