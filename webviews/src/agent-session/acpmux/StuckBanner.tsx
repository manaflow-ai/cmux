import React from "react";
import { useT } from "./i18n";

export type StuckBannerProps = {
  diagnosis: string;
  onNudge(): void;
};

/** A quiet, fixed-height attention row for a loop episode. The agent keeps running until the person acts. */
export function StuckBanner({ diagnosis, onNudge }: StuckBannerProps) {
  const t = useT();
  return (
    <output className="acpmux-stuck-banner" aria-live="polite">
      <span className="acpmux-stuck-ring" aria-hidden="true" />
      <span className="acpmux-stuck-copy">
        <strong>{t("stuck.title")}</strong>
        <span title={diagnosis}>{diagnosis}</span>
      </span>
      <button type="button" className="acpmux-stuck-nudge" onClick={onNudge}>
        {t("stuck.nudge")}
      </button>
    </output>
  );
}
