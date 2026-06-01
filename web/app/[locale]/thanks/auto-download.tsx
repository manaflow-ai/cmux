"use client";

import { useRef } from "react";
import posthog from "posthog-js";

export function AutoDownload({ url }: { url: string }) {
  const triggeredRef = useRef(false);

  const handleRef = (node: HTMLAnchorElement | null) => {
    if (!node || triggeredRef.current) return;
    triggeredRef.current = true;
    posthog.capture("cmuxterm_download_clicked", { location: "thanks-auto" });
    node.click();
  };

  return (
    <a
      ref={handleRef}
      href={url}
      download
      hidden
      aria-hidden="true"
      tabIndex={-1}
    />
  );
}
