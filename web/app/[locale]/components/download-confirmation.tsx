"use client";

import { useEffect, useRef } from "react";
import { useTranslations } from "next-intl";
import { DOWNLOAD_URL, DOWNLOAD_INTENT_PARAM } from "../../lib/download";
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

export function DownloadConfirmation() {
  const t = useTranslations("download");
  // Guard against React StrictMode's double-invoke (and any re-render) so the
  // download fires at most once per mount.
  const hasTriggered = useRef(false);

  useEffect(() => {
    if (hasTriggered.current) return;
    hasTriggered.current = true;
    // Auto-download only when the navigation carried the intent marker (set by
    // the Download CTAs). Reading the URL works for client-side `Link`
    // transitions, unlike the Performance navigation type which keeps the
    // original document's load type. Strip the marker afterwards so refreshing
    // or navigating back to this page does not re-trigger the download.
    const params = new URLSearchParams(window.location.search);
    if (params.get(DOWNLOAD_INTENT_PARAM) === "1") {
      triggerDownload();
      params.delete(DOWNLOAD_INTENT_PARAM);
      const query = params.toString();
      const cleanUrl =
        window.location.pathname +
        (query ? `?${query}` : "") +
        window.location.hash;
      window.history.replaceState(window.history.state, "", cleanUrl);
    }
  }, []);

  return (
    <main className="mx-auto w-full max-w-6xl px-6 py-16 sm:py-20">
      {/* Hero */}
      <div className="flex flex-col items-center text-center">
        {/* Plain <img> (raw PNG), not next/image, on purpose. The 34 KB
            256×256 logo shown at 48px gains nothing from the optimizer, and
            routing it through /_next/image broke this hero in Safari while
            Chrome rendered it (issue #5819): WebKit's HTTP cache mishandles the
            optimizer's `Vary: Accept` responses (compounded by the `priority`
            preload and `?dpl=`-pinned URLs across deploys), surfacing the
            broken-image glyph. The site header already serves /logo.png as a
            plain <img> and renders fine in Safari — this matches it.
            fetchPriority="high" preserves the above-the-fold load hint that
            `priority` provided. */}
        <img
          // Decorative: the heading below already names the product, so an
          // empty alt avoids an untranslated string for screen readers.
          src="/logo.png"
          alt=""
          width={48}
          height={48}
          className="rounded-xl"
          fetchPriority="high"
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

      {/* Official links — reused from the Community page (no heading here) */}
      <div className="mt-14">
        <OfficialLinks heading={false} />
      </div>
    </main>
  );
}
