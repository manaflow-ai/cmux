"use client";

import { useEffect, useRef } from "react";
import Image from "next/image";
import { useTranslations } from "next-intl";
import { Link } from "../../../i18n/navigation";
import { DOWNLOAD_URL } from "../../lib/download";

const DISCORD_URL = "https://discord.gg/xsgFEVrWCZ";
const X_URL = "https://twitter.com/manaflowai";
const DOCS_PATH = "/docs/getting-started";

function triggerDownload() {
  const anchor = document.createElement("a");
  anchor.href = DOWNLOAD_URL;
  // `download` is ignored for cross-origin URLs, but the GitHub release asset
  // is served with Content-Disposition: attachment, so the click downloads the
  // file without navigating away from this page.
  anchor.download = "";
  anchor.rel = "noopener";
  document.body.appendChild(anchor);
  anchor.click();
  anchor.remove();
}

export function DownloadConfirmation() {
  const t = useTranslations("download");
  // Guard against React StrictMode's double-invoke (and any re-render) so the
  // download fires exactly once on mount.
  const hasTriggered = useRef(false);

  useEffect(() => {
    if (hasTriggered.current) return;
    hasTriggered.current = true;
    triggerDownload();
  }, []);

  return (
    <main className="mx-auto w-full max-w-2xl px-6 py-16 sm:py-24">
      {/* Hero */}
      <div className="flex flex-col items-center text-center">
        <Image
          // Decorative: the heading below already names the product, so an
          // empty alt avoids an untranslated string for screen readers.
          src="/logo.png"
          alt=""
          width={48}
          height={48}
          className="rounded-xl"
          priority
        />
        <h1 className="mt-6 text-2xl sm:text-3xl font-semibold tracking-tight">
          {t("heading")}
        </h1>
        <p className="mt-3 text-[15px] text-muted" style={{ lineHeight: 1.5 }}>
          {t.rich("subtext", {
            link: (chunks) => (
              // A real anchor so the download still works without JS (the
              // auto-download useEffect won't run if the bundle never hydrates).
              <a
                href={DOWNLOAD_URL}
                className="underline underline-offset-2 decoration-border hover:decoration-foreground transition-colors"
              >
                {chunks}
              </a>
            ),
          })}
        </p>
      </div>

      {/* Resources */}
      <div className="mt-14 grid grid-cols-1 gap-3 sm:grid-cols-3">
        <Link
          href={DOCS_PATH}
          className="flex flex-col rounded-lg border border-border p-4 transition-colors hover:bg-code-bg"
        >
          <DocumentationIcon />
          <h2 className="mt-3 text-[15px] font-medium tracking-tight">
            {t("docs.title")}
          </h2>
          <p
            className="mt-1.5 text-[13px] text-muted"
            style={{ lineHeight: 1.5 }}
          >
            {t("docs.description")}
          </p>
        </Link>

        <a
          href={DISCORD_URL}
          target="_blank"
          rel="noopener noreferrer"
          className="flex flex-col rounded-lg border border-border p-4 transition-colors hover:bg-code-bg"
        >
          <DiscordIcon />
          <h2 className="mt-3 text-[15px] font-medium tracking-tight">
            {t("discord.title")}
          </h2>
          <p
            className="mt-1.5 text-[13px] text-muted"
            style={{ lineHeight: 1.5 }}
          >
            {t("discord.description")}
          </p>
        </a>

        <a
          href={X_URL}
          target="_blank"
          rel="noopener noreferrer"
          className="flex flex-col rounded-lg border border-border p-4 transition-colors hover:bg-code-bg"
        >
          <XIcon />
          <h2 className="mt-3 text-[15px] font-medium tracking-tight">
            {t("x.title")}
          </h2>
          <p
            className="mt-1.5 text-[13px] text-muted"
            style={{ lineHeight: 1.5 }}
          >
            {t("x.description")}
          </p>
        </a>
      </div>
    </main>
  );
}

function DocumentationIcon() {
  return (
    <svg
      width="20"
      height="20"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.5"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      className="text-foreground"
    >
      <path d="M4 19.5A2.5 2.5 0 0 1 6.5 17H20" />
      <path d="M6.5 2H20v20H6.5A2.5 2.5 0 0 1 4 19.5v-15A2.5 2.5 0 0 1 6.5 2z" />
      <path d="M9 7h7" />
      <path d="M9 11h7" />
    </svg>
  );
}

function DiscordIcon() {
  return (
    <svg
      width="20"
      height="20"
      viewBox="0 0 24 24"
      fill="currentColor"
      aria-hidden="true"
      className="text-foreground"
    >
      <path d="M20.317 4.369A19.79 19.79 0 0 0 15.885 3a.074.074 0 0 0-.079.037c-.21.375-.444.864-.608 1.249a18.27 18.27 0 0 0-5.487 0 12.6 12.6 0 0 0-.617-1.25.077.077 0 0 0-.079-.036A19.736 19.736 0 0 0 4.677 4.37a.07.07 0 0 0-.032.027C1.846 8.59 1.077 12.69 1.455 16.74a.082.082 0 0 0 .031.057 19.9 19.9 0 0 0 5.993 3.04.077.077 0 0 0 .084-.028 14.2 14.2 0 0 0 1.226-1.994.076.076 0 0 0-.041-.106 13.1 13.1 0 0 1-1.872-.892.077.077 0 0 1-.008-.128c.126-.094.252-.192.372-.291a.074.074 0 0 1 .077-.01c3.928 1.793 8.18 1.793 12.062 0a.074.074 0 0 1 .078.009c.12.099.246.198.373.292a.077.077 0 0 1-.006.127 12.3 12.3 0 0 1-1.873.891.077.077 0 0 0-.041.107c.36.698.772 1.362 1.225 1.993a.076.076 0 0 0 .084.028 19.84 19.84 0 0 0 6.002-3.04.077.077 0 0 0 .032-.054c.5-5.177-.838-9.674-3.549-13.66a.061.061 0 0 0-.031-.029zM8.02 14.331c-1.183 0-2.157-1.085-2.157-2.419 0-1.333.955-2.419 2.157-2.419 1.211 0 2.176 1.096 2.157 2.42 0 1.333-.955 2.418-2.157 2.418zm7.975 0c-1.183 0-2.157-1.085-2.157-2.419 0-1.333.955-2.419 2.157-2.419 1.21 0 2.176 1.096 2.157 2.42 0 1.333-.946 2.418-2.157 2.418z" />
    </svg>
  );
}

function XIcon() {
  return (
    <svg
      width="18"
      height="18"
      viewBox="0 0 24 24"
      fill="currentColor"
      aria-hidden="true"
      className="text-foreground"
    >
      <path d="M18.244 2.25h3.308l-7.227 8.26 8.502 11.24H16.17l-5.214-6.817L4.99 21.75H1.68l7.73-8.835L1.254 2.25H8.08l4.713 6.231zm-1.161 17.52h1.833L7.084 4.126H5.117z" />
    </svg>
  );
}
