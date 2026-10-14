import React, { useId, useState } from "react";
import { useT } from "../i18n";
import type { AcpmuxSessionOffer } from "../model";
import { errorMessage } from "../transportErrors";

/// An agent's offer of a parallel chat (cx-807da), where the agent made it in the chat: its title,
/// Start and Dismiss. Start starts the chat beside this one, which goes on; acpmux's record of the
/// answer turns the chip into Started (with Open) or Dismissed. A placeholder look until the
/// chip's design lands; the `session-offer` experiment draws it.
export function OfferChip({
  offer,
  onStart,
  onDismiss,
  onOpen,
}: {
  offer: AcpmuxSessionOffer;
  onStart(): Promise<unknown>;
  onDismiss(): Promise<unknown>;
  onOpen(childSessionId: string): void;
}) {
  const t = useT();
  const [busy, setBusy] = useState<"start" | "dismiss">();
  const [error, setError] = useState<string>();
  const titleId = useId();
  // Busy until acpmux's decision record answers the chip, so its buttons never come back between.
  const run = (which: "start" | "dismiss", action: () => Promise<unknown>) => {
    setBusy(which);
    setError(undefined);
    action().catch((failure: unknown) => {
      setBusy(undefined);
      setError(errorMessage(failure) || t("offer.failed"));
    });
  };
  const child = offer.childSessionId;
  return (
    <div className="acpmux-session-offer" data-outcome={offer.outcome ?? "open"}>
      <div className="acpmux-session-offer-text">
        <span className="acpmux-session-offer-label">
          {t("offer.label")}
          {offer.worktree && ` · ${t("offer.worktree")}`}
        </span>
        <span className="acpmux-session-offer-title" id={titleId}>
          {offer.title}
        </span>
        {error && (
          <span className="acpmux-session-offer-error" role="alert">
            {error}
          </span>
        )}
      </div>
      <div className="acpmux-session-offer-row" aria-live="polite">
        {offer.outcome === "accepted" ? (
          <>
            <span className="acpmux-session-offer-status">{t("offer.started")}</span>
            {child && (
              <button
                type="button"
                className="acpmux-session-offer-action"
                aria-describedby={titleId}
                onClick={() => onOpen(child)}
              >
                {t("offer.open")}
              </button>
            )}
          </>
        ) : offer.outcome === "dismissed" ? (
          <span className="acpmux-session-offer-status">{t("offer.dismissed")}</span>
        ) : busy === "start" ? (
          <span className="acpmux-session-offer-status">{t("offer.starting")}</span>
        ) : (
          <>
            <button
              type="button"
              className="acpmux-session-offer-action"
              aria-describedby={titleId}
              disabled={busy !== undefined}
              onClick={() => run("start", onStart)}
            >
              {t("offer.start")}
            </button>
            <button
              type="button"
              className="acpmux-session-offer-action"
              aria-describedby={titleId}
              disabled={busy !== undefined}
              onClick={() => run("dismiss", onDismiss)}
            >
              {t("offer.dismiss")}
            </button>
          </>
        )}
      </div>
    </div>
  );
}
