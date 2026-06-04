"use client";

import { useEffect, useRef } from "react";
import Image from "next/image";
import { useTranslations } from "next-intl";
import { DOWNLOAD_URL } from "../../lib/download";
import { OfficialLinks } from "./official-links";

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

/** True only on a fresh forward navigation — not a reload or back/forward. */
function isFreshNavigation() {
  const entries = performance.getEntriesByType(
    "navigation",
  ) as PerformanceNavigationTiming[];
  // Default to triggering when the type is unavailable (older browsers).
  return entries.length === 0 || entries[0].type === "navigate";
}

export function DownloadConfirmation() {
  const t = useTranslations("download");
  // Guard against React StrictMode's double-invoke (and any re-render) so the
  // download fires at most once per mount.
  const hasTriggered = useRef(false);

  useEffect(() => {
    if (hasTriggered.current) return;
    hasTriggered.current = true;
    // Only auto-download when the user actually navigated here (e.g. clicked a
    // Download button). Refreshing the page or using back/forward must NOT
    // re-trigger the download; the manual "Click here" link is always available.
    if (isFreshNavigation()) triggerDownload();
  }, []);

  return (
    <main className="mx-auto w-full max-w-6xl px-6 py-16 sm:py-20">
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

      {/* Official links — reused from the Community page */}
      <div className="mt-14">
        <OfficialLinks />
      </div>
    </main>
  );
}
