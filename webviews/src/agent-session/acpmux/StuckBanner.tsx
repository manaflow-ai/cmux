import React from "react";

export type StuckBannerProps = {
  diagnosis: string;
  onNudge(): void;
};

/** A quiet, fixed-height attention row for a loop episode. The agent keeps running until the person acts. */
export function StuckBanner({ diagnosis, onNudge }: StuckBannerProps) {
  return (
    <aside className="acpmux-stuck-banner" role="status" aria-live="polite">
      <span className="acpmux-stuck-ring" aria-hidden="true" />
      <span className="acpmux-stuck-copy">
        <strong>Agent may be stuck</strong>
        <span title={diagnosis}>{diagnosis}</span>
      </span>
      <button type="button" className="acpmux-stuck-nudge" onClick={onNudge}>
        Nudge with hint
      </button>
    </aside>
  );
}
