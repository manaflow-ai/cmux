"use client";

import posthog from "posthog-js";
import type { DownloadPlatform } from "@/app/lib/download";

export type BrowserDownloadPlatform = DownloadPlatform | "macos";

/** Emits download intent telemetry before following an artifact link. */
export function PlatformDownloadLink({
  href,
  platform,
  artifact,
  location,
  className,
  style,
  children,
}: {
  href: string;
  platform: BrowserDownloadPlatform;
  artifact: string;
  location: string;
  className?: string;
  style?: React.CSSProperties;
  children: React.ReactNode;
}) {
  return (
    <a
      href={href}
      className={className}
      style={style}
      onClick={() =>
        posthog.capture(
          "cmux_browser_download_clicked",
          {
            platform,
            artifact,
            location,
            target: href,
          },
          {
            transport: "sendBeacon",
            send_instantly: true,
          },
        )
      }
    >
      {children}
    </a>
  );
}
