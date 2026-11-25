"use client";

import { useLocale, useTranslations } from "next-intl";
import { useSyncExternalStore } from "react";
import { routing } from "../../../i18n/routing";
import {
  ANALYTICS_CONSENT_CHANGED_EVENT,
  ANALYTICS_CONSENT_STORAGE_KEY,
  readAnalyticsConsent,
  setAnalyticsConsent,
  type AnalyticsConsent,
} from "../../lib/posthog-client";

/** "unset": the visitor has not chosen, so analytics stay off. "server": not read yet (server render). */
type ConsentState = AnalyticsConsent | "unset" | "server";

function subscribe(onChange: () => void) {
  const onStorage = (event: StorageEvent) => {
    if (event.key === ANALYTICS_CONSENT_STORAGE_KEY) onChange();
  };
  window.addEventListener(ANALYTICS_CONSENT_CHANGED_EVENT, onChange);
  window.addEventListener("storage", onStorage);
  return () => {
    window.removeEventListener(ANALYTICS_CONSENT_CHANGED_EVENT, onChange);
    window.removeEventListener("storage", onStorage);
  };
}

/** The visitor's analytics choice; anything but "granted" means analytics are off. */
export function useAnalyticsConsent(): ConsentState {
  return useSyncExternalStore(
    subscribe,
    () => readAnalyticsConsent() ?? "unset",
    () => "server",
  );
}

/**
 * Asks once whether the visitor allows analytics. Until they accept, PostHog
 * is not loaded: no cookie, no identify, no capture.
 */
export function AnalyticsConsentBanner() {
  // Nothing renders on the server or once the visitor has chosen, so the
  // banner's text and links load only when it is actually shown.
  if (useAnalyticsConsent() !== "unset") return null;
  return <AnalyticsConsentNotice />;
}

function AnalyticsConsentNotice() {
  const t = useTranslations("analyticsConsent");
  const locale = useLocale();
  // A plain link (locale prefix "as-needed"), so this client component does
  // not pull in next-intl's navigation and its server-side redirect helpers.
  const privacyHref = locale === routing.defaultLocale ? "/privacy-policy" : `/${locale}/privacy-policy`;

  return (
    <div
      role="region"
      aria-label={t("label")}
      className="fixed inset-x-3 bottom-3 z-50 mx-auto flex max-w-xl flex-col gap-3 rounded-lg border border-border bg-background/95 px-4 py-3 text-[14px] shadow-lg backdrop-blur sm:flex-row sm:items-center"
    >
      <p className="flex-1 text-muted">
        {t("message")}{" "}
        <a
          href={privacyHref}
          className="underline underline-offset-2 decoration-link-underline hover:decoration-foreground transition-colors"
        >
          {t("privacy")}
        </a>
      </p>
      <div className="flex shrink-0 gap-2">
        <button
          type="button"
          onClick={() => setAnalyticsConsent("denied")}
          className="rounded-md border border-border px-3 py-1.5 hover:bg-code-bg transition-colors"
        >
          {t("decline")}
        </button>
        <button
          type="button"
          onClick={() => setAnalyticsConsent("granted")}
          className="rounded-md bg-foreground px-3 py-1.5 text-background hover:opacity-90 transition-opacity"
        >
          {t("accept")}
        </button>
      </div>
    </div>
  );
}

/** A footer control that asks again: it forgets the choice (analytics off) and shows the notice. */
export function AnalyticsSettingsButton({ className }: { className?: string }) {
  const t = useTranslations("analyticsConsent");
  return (
    <button type="button" onClick={() => setAnalyticsConsent(null)} className={className}>
      {t("settings")}
    </button>
  );
}
