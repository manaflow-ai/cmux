import Image from "next/image";
import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { buildAlternates } from "../../../i18n/seo";
import { SiteHeader } from "../components/site-header";
import { AutoDownload } from "./auto-download";

const DMG_URL =
  "https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg";
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
  children,
}: {
  n: number;
  title: string;
  children: React.ReactNode;
}) {
  return (
    <div className="rounded-2xl border border-border bg-code-bg/40 p-5 flex flex-col items-center text-center">
      <div className="size-7 rounded-full bg-foreground text-background text-xs font-semibold flex items-center justify-center mb-4">
        {n}
      </div>
      <div className="w-full aspect-[11/7] flex items-center justify-center mb-4 overflow-hidden">
        {children}
      </div>
      <p className="text-[15px] leading-snug">{title}</p>
    </div>
  );
}

function DragToApplicationsSvg({ title }: { title: string }) {
  return (
    <svg
      xmlns="http://www.w3.org/2000/svg"
      viewBox="0 0 880 560"
      className="w-full h-full"
      role="img"
      aria-label={title}
    >
      <defs>
        <linearGradient id="cmuxBlue1" x1="0" y1="0" x2="1" y2="1">
          <stop offset="0%" stopColor="#4a8cff" />
          <stop offset="100%" stopColor="#1f6cff" />
        </linearGradient>
        <linearGradient id="folderBlue" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" stopColor="#5aa6ff" />
          <stop offset="100%" stopColor="#1f6cff" />
        </linearGradient>
        <linearGradient id="folderTab" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" stopColor="#7ab9ff" />
          <stop offset="100%" stopColor="#3d83e6" />
        </linearGradient>
        <linearGradient id="iconShine1" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" stopColor="#ffffff" />
          <stop offset="100%" stopColor="#f1f3f7" />
        </linearGradient>
        <filter
          id="softShadow1"
          x="-20%"
          y="-20%"
          width="140%"
          height="140%"
        >
          <feGaussianBlur in="SourceAlpha" stdDeviation="6" />
          <feOffset dx="0" dy="6" />
          <feComponentTransfer>
            <feFuncA type="linear" slope="0.28" />
          </feComponentTransfer>
          <feMerge>
            <feMergeNode />
            <feMergeNode in="SourceGraphic" />
          </feMerge>
        </filter>
        <filter
          id="softShadow2"
          x="-20%"
          y="-20%"
          width="140%"
          height="140%"
        >
          <feGaussianBlur in="SourceAlpha" stdDeviation="8" />
          <feOffset dx="0" dy="8" />
          <feComponentTransfer>
            <feFuncA type="linear" slope="0.32" />
          </feComponentTransfer>
          <feMerge>
            <feMergeNode />
            <feMergeNode in="SourceGraphic" />
          </feMerge>
        </filter>
        <marker
          id="arrowHead"
          viewBox="0 0 12 12"
          refX="6"
          refY="6"
          markerWidth="10"
          markerHeight="10"
          orient="auto-start-reverse"
        >
          <path d="M0,0 L12,6 L0,12 L3,6 Z" fill="#7a8597" />
        </marker>
      </defs>

      <g transform="translate(180 280) rotate(-8)" filter="url(#softShadow1)">
        <rect
          x="-110"
          y="-110"
          width="220"
          height="220"
          rx="50"
          ry="50"
          fill="url(#iconShine1)"
          stroke="#e3e6ec"
          strokeWidth="1"
        />
        <rect
          x="-110"
          y="-110"
          width="220"
          height="36"
          rx="50"
          ry="50"
          fill="#ffffff"
          opacity="0.6"
        />
        <path
          d="M -38 -52 L 40 0 L -38 52"
          fill="none"
          stroke="url(#cmuxBlue1)"
          strokeWidth="22"
          strokeLinecap="round"
          strokeLinejoin="round"
        />
      </g>

      <g
        transform="translate(252 348)"
        fill="#ffffff"
        stroke="#1a1a1a"
        strokeWidth="2"
        strokeLinejoin="round"
      >
        <path d="M0 0 L0 30 L8 22 L13 33 L18 31 L13 20 L24 20 Z" />
      </g>

      <g
        fill="none"
        stroke="#7a8597"
        strokeWidth="3.5"
        strokeLinecap="round"
        strokeDasharray="2 12"
        opacity="0.7"
      >
        <path
          d="M 320 200 Q 440 100 560 200"
          markerEnd="url(#arrowHead)"
        />
      </g>

      <g transform="translate(700 280)" filter="url(#softShadow2)">
        <path
          d="M -150 -90 L -60 -90 L -40 -70 L 150 -70 L 150 -50 L -150 -50 Z"
          fill="url(#folderTab)"
        />
        <rect
          x="-150"
          y="-72"
          width="300"
          height="180"
          rx="20"
          ry="20"
          fill="url(#folderBlue)"
        />
        <path
          d="M -150 -52 Q 0 -40 150 -52 L 150 -40 Q 0 -28 -150 -40 Z"
          fill="#ffffff"
          opacity="0.18"
        />
        <g fill="#ffffff">
          <path d="M -44 60 L 0 -42 L 44 60 L 24 60 L 14 36 L -14 36 L -24 60 Z M -7 18 L 7 18 L 0 1 Z" />
        </g>
      </g>
    </svg>
  );
}

function DockSvg({ title }: { title: string }) {
  return (
    <svg
      xmlns="http://www.w3.org/2000/svg"
      viewBox="0 0 880 560"
      className="w-full h-full"
      role="img"
      aria-label={title}
    >
      <defs>
        <linearGradient id="cmuxBlue2" x1="0" y1="0" x2="1" y2="1">
          <stop offset="0%" stopColor="#4a8cff" />
          <stop offset="100%" stopColor="#1f6cff" />
        </linearGradient>
        <linearGradient id="finderBlue" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" stopColor="#7fb3ff" />
          <stop offset="100%" stopColor="#2e6ff0" />
        </linearGradient>
        <linearGradient id="messagesGreen" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" stopColor="#5be37b" />
          <stop offset="100%" stopColor="#1aab46" />
        </linearGradient>
        <linearGradient id="dockGlass" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" stopColor="#3a3f4a" stopOpacity="0.55" />
          <stop offset="100%" stopColor="#1a1d24" stopOpacity="0.65" />
        </linearGradient>
        <linearGradient id="dockHighlight" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" stopColor="#ffffff" stopOpacity="0.45" />
          <stop offset="100%" stopColor="#ffffff" stopOpacity="0" />
        </linearGradient>
        <linearGradient id="iconShine2" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" stopColor="#ffffff" />
          <stop offset="100%" stopColor="#eef0f5" />
        </linearGradient>
        <filter
          id="dockShadow"
          x="-10%"
          y="-30%"
          width="120%"
          height="180%"
        >
          <feGaussianBlur in="SourceAlpha" stdDeviation="14" />
          <feOffset dx="0" dy="18" />
          <feComponentTransfer>
            <feFuncA type="linear" slope="0.35" />
          </feComponentTransfer>
          <feMerge>
            <feMergeNode />
            <feMergeNode in="SourceGraphic" />
          </feMerge>
        </filter>
        <filter
          id="iconShadow"
          x="-30%"
          y="-30%"
          width="160%"
          height="160%"
        >
          <feGaussianBlur in="SourceAlpha" stdDeviation="3" />
          <feOffset dx="0" dy="3" />
          <feComponentTransfer>
            <feFuncA type="linear" slope="0.35" />
          </feComponentTransfer>
          <feMerge>
            <feMergeNode />
            <feMergeNode in="SourceGraphic" />
          </feMerge>
        </filter>
      </defs>

      <g transform="translate(440 320)" filter="url(#dockShadow)">
        <rect
          x="-300"
          y="-90"
          width="600"
          height="180"
          rx="56"
          ry="56"
          fill="url(#dockGlass)"
          stroke="#ffffff"
          strokeOpacity="0.18"
          strokeWidth="1.5"
        />
        <rect
          x="-292"
          y="-86"
          width="584"
          height="60"
          rx="44"
          ry="44"
          fill="url(#dockHighlight)"
          opacity="0.7"
        />
      </g>

      <g transform="translate(280 320)" filter="url(#iconShadow)">
        <rect
          x="-66"
          y="-66"
          width="132"
          height="132"
          rx="30"
          ry="30"
          fill="url(#finderBlue)"
        />
        <path d="M 0 -52 A 52 52 0 0 1 0 52 Z" fill="#ffffff" />
        <rect x="-22" y="-26" width="8" height="22" rx="3" fill="#1a3a78" />
        <rect x="14" y="-26" width="8" height="22" rx="3" fill="#1a3a78" />
        <path
          d="M -22 18 Q 0 34 22 18"
          fill="none"
          stroke="#1a3a78"
          strokeWidth="5"
          strokeLinecap="round"
        />
      </g>

      <g transform="translate(440 320)" filter="url(#iconShadow)">
        <rect
          x="-66"
          y="-66"
          width="132"
          height="132"
          rx="30"
          ry="30"
          fill="url(#iconShine2)"
          stroke="#dfe3ea"
          strokeWidth="1"
        />
        <rect
          x="-66"
          y="-66"
          width="132"
          height="22"
          rx="30"
          ry="30"
          fill="#ffffff"
          opacity="0.7"
        />
        <path
          d="M -22 -32 L 24 0 L -22 32"
          fill="none"
          stroke="url(#cmuxBlue2)"
          strokeWidth="14"
          strokeLinecap="round"
          strokeLinejoin="round"
        />
      </g>

      <g transform="translate(600 320)" filter="url(#iconShadow)">
        <rect
          x="-66"
          y="-66"
          width="132"
          height="132"
          rx="30"
          ry="30"
          fill="url(#messagesGreen)"
        />
        <path
          d="M -38 -22 Q -38 -42 -18 -42 L 30 -42 Q 50 -42 50 -22 L 50 6 Q 50 26 30 26 L 4 26 L -14 42 L -10 26 L -18 26 Q -38 26 -38 6 Z"
          fill="#ffffff"
        />
      </g>

      <circle cx="440" cy="412" r="4" fill="#ffffff" opacity="0.85" />
    </svg>
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
        <div className="flex justify-center mb-12">
          <p className="inline-flex items-center rounded-full border border-border bg-code-bg/60 px-4 py-2 text-sm text-muted">
            {t("downloadStarted")}&nbsp;
            <a
              href={DMG_URL}
              className="underline underline-offset-2 decoration-border hover:decoration-foreground transition-colors text-foreground"
            >
              {t("tryAgain")}
            </a>
          </p>
        </div>

        <h1 className="text-3xl sm:text-4xl font-semibold tracking-tight text-center mb-3">
          {t("title")}
        </h1>
        <p className="text-muted text-center text-[15px] mb-12">
          {t("subtitle")}
        </p>

        <div className="grid gap-4 sm:grid-cols-3 mb-16">
          <Step n={1} title={t("step1")}>
            <Image
              src="/install/step1.png"
              alt={t("step1Alt")}
              width={880}
              height={560}
              className="w-full h-full object-contain"
              priority
            />
          </Step>
          <Step n={2} title={t("step2")}>
            <DragToApplicationsSvg title={t("step2Alt")} />
          </Step>
          <Step n={3} title={t("step3")}>
            <DockSvg title={t("step3Alt")} />
          </Step>
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
