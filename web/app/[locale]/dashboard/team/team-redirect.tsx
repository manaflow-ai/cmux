"use client";

import { useTranslations } from "next-intl";
import { useCallback } from "react";
import { Link, useRouter } from "@/i18n/navigation";
import { DEFAULT_SETTINGS_ROUTE, settingsRouteForHash } from "./team-hash-redirect";

/**
 * Maps the old Hexclave hash (for example `#team-<id>`) to its cmux route.
 * The hash only exists in the browser, so the redirect runs from a callback
 * ref when this element mounts; the link covers a stalled navigation.
 */
export function TeamHashRedirect() {
  const t = useTranslations("dashboard.settings.redirect");
  const router = useRouter();
  const redirectOnMount = useCallback(
    (node: HTMLElement | null) => {
      if (node) router.replace(settingsRouteForHash(window.location.hash));
    },
    [router],
  );

  return (
    <p ref={redirectOnMount} data-testid="team-hash-redirect" className="px-3 py-4 text-muted">
      {t("redirecting")}{" "}
      <Link href={DEFAULT_SETTINGS_ROUTE} className="underline">
        {t("openSettings")}
      </Link>
    </p>
  );
}
