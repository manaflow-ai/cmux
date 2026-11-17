"use client";

import { useEffect, useRef, useState } from "react";
import { canAutoOpen } from "../deeplink/[kind]/auto-open";
import { DOWNLOAD_URL } from "@/app/lib/download";

/**
 * The install handoff (contract.md "Additions" 4, install.md "Handoff"): on a
 * Mac, hand the validated cmux:// link to the app on load. Without cmux, the
 * Download button starts the DMG here, the page keeps the link, and every time
 * the window regains focus (the person comes back after installing cmux) it
 * offers the link again. Only ever opens the href the server built.
 */
export function InstallHandoff({
  href,
  autoOpen,
  autoDownload = false,
  labels,
}: {
  href: string;
  autoOpen: boolean;
  autoDownload?: boolean;
  labels: { open: string; download: string; noCmux: string; downloadBody: string };
}) {
  // The download page starts the download on load, so it is "downloaded" from the first render.
  const [downloaded, setDownloaded] = useState(autoDownload);
  const started = useRef(false);

  useEffect(() => {
    if (started.current) return;
    started.current = true;
    if (autoDownload) {
      startDownload();
    } else if (autoOpen && canAutoOpen(window.navigator)) {
      window.location.href = href;
    }
  }, [autoDownload, autoOpen, href]);

  useEffect(() => {
    if (!downloaded) return;
    const retry = () => {
      if (canAutoOpen(window.navigator)) window.location.href = href;
    };
    window.addEventListener("focus", retry);
    return () => window.removeEventListener("focus", retry);
  }, [downloaded, href]);

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap gap-3">
        <a
          href={href}
          className="inline-flex items-center rounded-full bg-foreground px-6 py-2.5 text-[15px] font-medium transition-opacity hover:opacity-85"
          style={{ color: "var(--background)", textDecoration: "none" }}
        >
          {labels.open}
        </a>
      </div>
      <div className="rounded-xl border border-border px-5 py-4">
        <p className="text-[14px] font-medium">{labels.noCmux}</p>
        <p className="mt-1 text-[14px] leading-6 text-muted">{labels.downloadBody}</p>
        <a
          href={DOWNLOAD_URL}
          onClick={(event) => {
            event.preventDefault();
            startDownload();
            setDownloaded(true);
          }}
          className="mt-3 inline-flex items-center rounded-full border border-border px-5 py-2 text-[14px] font-medium transition-colors hover:bg-code-bg"
        >
          {labels.download}
        </a>
      </div>
    </div>
  );
}

function startDownload() {
  const anchor = document.createElement("a");
  anchor.href = DOWNLOAD_URL;
  // The release asset is served as an attachment, so the page stays while it downloads.
  anchor.download = "";
  anchor.rel = "noopener";
  document.body.appendChild(anchor);
  anchor.click();
  anchor.remove();
}
