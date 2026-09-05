"use client";

import posthog from "posthog-js";
import { DOWNLOAD_URL } from "../../lib/download";

/** Direct release-asset link for the global 404, which has no locale provider. */
export function NotFoundDownloadLink({
  className,
  children,
}: {
  className?: string;
  children: React.ReactNode;
}) {
  return (
    <a
      href={DOWNLOAD_URL}
      download=""
      rel="noopener"
      className={className}
      onClick={() =>
        posthog.capture(
          "cmuxterm_download_clicked",
          { location: "not_found", platform: "mac", target: DOWNLOAD_URL },
          { transport: "sendBeacon", send_instantly: true },
        )
      }
    >
      {children}
    </a>
  );
}
