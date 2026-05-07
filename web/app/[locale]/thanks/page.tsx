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
        <linearGradient id="s1-iconFill" x1="110" y1="0" x2="110" y2="220" gradientUnits="userSpaceOnUse">
          <stop offset="0" stopColor="#ffffff" />
          <stop offset="0.58" stopColor="#fbfcfe" />
          <stop offset="1" stopColor="#eef3f9" />
        </linearGradient>
        <linearGradient id="s1-chevronFill" x1="84" y1="72" x2="146" y2="148" gradientUnits="userSpaceOnUse">
          <stop offset="0" stopColor="#4a8cff" />
          <stop offset="1" stopColor="#1f6cff" />
        </linearGradient>
        <linearGradient id="s1-folderBack" x1="152" y1="24" x2="152" y2="94" gradientUnits="userSpaceOnUse">
          <stop offset="0" stopColor="#a9dbff" />
          <stop offset="1" stopColor="#5f9ff0" />
        </linearGradient>
        <linearGradient id="s1-folderFront" x1="152" y1="76" x2="152" y2="220" gradientUnits="userSpaceOnUse">
          <stop offset="0" stopColor="#7fc4ff" />
          <stop offset="1" stopColor="#2e7be0" />
        </linearGradient>
        <filter id="s1-blur12" x="-40%" y="-40%" width="180%" height="180%">
          <feGaussianBlur stdDeviation="10" />
        </filter>
        <filter id="s1-blur8" x="-40%" y="-40%" width="180%" height="180%">
          <feGaussianBlur stdDeviation="6" />
        </filter>
        <marker id="s1-dragArrow" viewBox="0 0 10 10" refX="8.5" refY="5" markerWidth="10" markerHeight="10" orient="auto">
          <path d="M1 1.2L8.6 5L1 8.8" fill="none" stroke="currentColor" strokeOpacity="0.56" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" />
        </marker>
      </defs>

      <g transform="translate(88 156) rotate(-6 110 110)">
        <path d="M56 0H164C197 0 220 23 220 56V164C220 197 197 220 164 220H56C23 220 0 197 0 164V56C0 23 23 0 56 0Z" transform="translate(8 12)" fill="#000000" fillOpacity="0.15" filter="url(#s1-blur12)" />
        <path d="M56 0H164C197 0 220 23 220 56V164C220 197 197 220 164 220H56C23 220 0 197 0 164V56C0 23 23 0 56 0Z" fill="url(#s1-iconFill)" stroke="#8893a3" strokeOpacity="0.18" />
        <path d="M63 8H157C186 8 212 28 212 63V157C212 192 192 212 157 212H63C28 212 8 192 8 157V63C8 28 28 8 63 8Z" fill="none" stroke="#ffffff" strokeOpacity="0.72" strokeWidth="2" />
        <image href="/install/cmux-chevron.png" x="56" y="40" width="120" height="140" preserveAspectRatio="xMidYMid meet" />
      </g>

      <path d="M306 242C383 155 493 153 573 226" fill="none" stroke="currentColor" strokeOpacity="0.48" strokeWidth="3.5" strokeLinecap="round" strokeDasharray="7 11" markerEnd="url(#s1-dragArrow)" />

      <g transform="translate(516 154)">
        <ellipse cx="152" cy="214" rx="116" ry="16" fill="#000000" fillOpacity="0.12" filter="url(#s1-blur8)" />
        <path d="M24 94V48C24 34 36 24 50 24H100C116 24 127 29 135 41L143 52H252C268 52 280 64 280 80V94H24Z" fill="url(#s1-folderBack)" stroke="#175291" strokeOpacity="0.12" />
        <path d="M16 94C16 84 24 76 34 76H270C280 76 288 84 288 94V182C288 203 271 220 250 220H54C33 220 16 203 16 182V94Z" fill="url(#s1-folderFront)" stroke="#12447e" strokeOpacity="0.14" />
        <path d="M40 55H126C132 55 137 57 141 61" fill="none" stroke="#ffffff" strokeOpacity="0.38" strokeWidth="3" strokeLinecap="round" />
        <path d="M38 95H266" fill="none" stroke="#ffffff" strokeOpacity="0.42" strokeWidth="3" strokeLinecap="round" />
        <path d="M105 171C120 145 134 119 151 93" fill="none" stroke="#ffffff" strokeWidth="20" strokeLinecap="round" strokeLinejoin="round" />
        <path d="M211 171C195 142 181 117 151 93" fill="none" stroke="#ffffff" strokeWidth="20" strokeLinecap="round" strokeLinejoin="round" />
        <path d="M121 145C144 141 168 141 191 145" fill="none" stroke="#ffffff" strokeWidth="18" strokeLinecap="round" strokeLinejoin="round" />
      </g>

      <g transform="translate(278 334) rotate(10)">
        <path d="M0 0V40L10 30L19 50L29 45L20 25H38L0 0Z" transform="translate(2 3)" fill="#000000" fillOpacity="0.18" filter="url(#s1-blur8)" />
        <path d="M0 0V40L10 30L19 50L29 45L20 25H38L0 0Z" fill="#ffffff" stroke="#0f1115" strokeWidth="2.2" strokeLinejoin="round" />
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
        <linearGradient id="s2-dockFill" x1="440" y1="215" x2="440" y2="389" gradientUnits="userSpaceOnUse">
          <stop offset="0" stopColor="#2c2f38" stopOpacity="0.55" />
          <stop offset="1" stopColor="#15171c" stopOpacity="0.65" />
        </linearGradient>
        <linearGradient id="s2-dockHighlight" x1="440" y1="228" x2="440" y2="272" gradientUnits="userSpaceOnUse">
          <stop offset="0" stopColor="#ffffff" stopOpacity="0.26" />
          <stop offset="1" stopColor="#ffffff" stopOpacity="0" />
        </linearGradient>
        <linearGradient id="s2-finderFill" x1="70" y1="0" x2="70" y2="140" gradientUnits="userSpaceOnUse">
          <stop offset="0" stopColor="#6aa6ff" />
          <stop offset="1" stopColor="#2e6ff0" />
        </linearGradient>
        <linearGradient id="s2-cmuxFill" x1="70" y1="0" x2="70" y2="140" gradientUnits="userSpaceOnUse">
          <stop offset="0" stopColor="#ffffff" />
          <stop offset="1" stopColor="#eef2f9" />
        </linearGradient>
        <linearGradient id="s2-cmuxChevron" x1="49" y1="43" x2="90" y2="97" gradientUnits="userSpaceOnUse">
          <stop offset="0" stopColor="#4a8cff" />
          <stop offset="1" stopColor="#1f6cff" />
        </linearGradient>
        <linearGradient id="s2-messageFill" x1="70" y1="0" x2="70" y2="140" gradientUnits="userSpaceOnUse">
          <stop offset="0" stopColor="#5ee07b" />
          <stop offset="1" stopColor="#18a943" />
        </linearGradient>
        <filter id="s2-blur14" x="-35%" y="-35%" width="170%" height="170%">
          <feGaussianBlur stdDeviation="14" />
        </filter>
        <filter id="s2-blur18" x="-35%" y="-35%" width="170%" height="170%">
          <feGaussianBlur stdDeviation="18" />
        </filter>
        <clipPath id="s2-finderClip">
          <path d="M34 0H106C126 0 140 14 140 34V106C140 126 126 140 106 140H34C14 140 0 126 0 106V34C0 14 14 0 34 0Z" />
        </clipPath>
      </defs>

      <rect x="130" y="233" width="620" height="174" rx="56" fill="#000000" fillOpacity="0.32" filter="url(#s2-blur14)" />
      <ellipse cx="440" cy="414" rx="250" ry="24" fill="#000000" fillOpacity="0.14" filter="url(#s2-blur18)" />

      <rect x="130" y="215" width="620" height="174" rx="56" fill="url(#s2-dockFill)" />
      <rect x="130.5" y="215.5" width="619" height="173" rx="55.5" fill="none" stroke="#ffffff" strokeOpacity="0.16" />
      <rect x="144" y="227" width="592" height="40" rx="32" fill="url(#s2-dockHighlight)" />

      <g transform="translate(190 233)">
        <path d="M34 0H106C126 0 140 14 140 34V106C140 126 126 140 106 140H34C14 140 0 126 0 106V34C0 14 14 0 34 0Z" fill="url(#s2-finderFill)" stroke="#ffffff" strokeOpacity="0.12" />
        <rect x="70" y="0" width="70" height="140" fill="#ffffff" clipPath="url(#s2-finderClip)" />
        <path d="M70 14V104" fill="none" stroke="#1a3a78" strokeOpacity="0.9" strokeWidth="4.5" strokeLinecap="round" />
        <path d="M39 58C43 54 49 54 53 58" fill="none" stroke="#1a3a78" strokeWidth="4.5" strokeLinecap="round" />
        <path d="M87 58C91 54 97 54 101 58" fill="none" stroke="#1a3a78" strokeWidth="4.5" strokeLinecap="round" />
        <path d="M46 93C57 104 83 104 94 93" fill="none" stroke="#18243b" strokeWidth="5" strokeLinecap="round" />
      </g>

      <g transform="translate(370 233)">
        <path d="M34 0H106C126 0 140 14 140 34V106C140 126 126 140 106 140H34C14 140 0 126 0 106V34C0 14 14 0 34 0Z" fill="url(#s2-cmuxFill)" stroke="#94a0b2" strokeOpacity="0.18" />
        <path d="M40 6H100C121 6 134 19 134 40V100C134 121 121 134 100 134H40C19 134 6 121 6 100V40C6 19 19 6 40 6Z" fill="none" stroke="#ffffff" strokeOpacity="0.68" strokeWidth="1.8" />
        <image href="/install/cmux-chevron.png" x="32" y="22" width="76" height="96" preserveAspectRatio="xMidYMid meet" />
      </g>

      <g transform="translate(550 233)">
        <path d="M34 0H106C126 0 140 14 140 34V106C140 126 126 140 106 140H34C14 140 0 126 0 106V34C0 14 14 0 34 0Z" fill="url(#s2-messageFill)" stroke="#ffffff" strokeOpacity="0.12" />
        <path d="M44 49H97C108 49 117 58 117 69V87C117 98 108 107 97 107H67L50 120L55 107H44C33 107 24 98 24 87V69C24 58 33 49 44 49Z" fill="none" stroke="#ffffff" strokeWidth="11" strokeLinecap="round" strokeLinejoin="round" />
      </g>

      <circle cx="440" cy="405" r="4.5" fill="#ffffff" fillOpacity="0.56" />
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
