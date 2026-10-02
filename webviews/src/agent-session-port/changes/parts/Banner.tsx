// Tracked-only warning card under the header, and the centered load-state message.
import * as I from "../icons";
import type { ChangesBanner } from "../types";

export function Banner({ banner, onRefresh }: { banner: ChangesBanner; onRefresh: () => void }) {
  return (
    <output className="cx-banner">
      <I.AlertCircle className="cx-banner-icon" width={17} height={17} />
      <div className="cx-banner-text">
        <div className="cx-banner-title">{banner.title}</div>
        <div className="cx-banner-body">{banner.body}</div>
      </div>
      <span className="cx-banner-divider" />
      <button
        type="button"
        className="cx-banner-action"
        onClick={() => navigator.clipboard?.writeText("git clean -ndX")}
      >
        {banner.actionLabel}
      </button>
      <button type="button" className="cx-banner-secondary" onClick={onRefresh}>
        {banner.secondaryLabel}
      </button>
    </output>
  );
}

/** "Couldn't load changes" (or "No changes") centered over the diff column. */
export function LoadMessage({
  title,
  body,
  action,
  onAction,
}: {
  title: string;
  body: string;
  action: string | null;
  onAction: () => void;
}) {
  return (
    <div className="cx-load-message" role={action ? "alert" : "status"}>
      <h3>{title}</h3>
      <p>{body}</p>
      {action && (
        <button type="button" className="cx-load-message-action" onClick={onAction}>
          {action}
        </button>
      )}
    </div>
  );
}
