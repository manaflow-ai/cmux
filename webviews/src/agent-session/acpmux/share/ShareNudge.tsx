// The share nudge's line (shareNudgeModel.ts says when it shows): "Teammates can watch or join this
// chat." with Share… (the Share dialog, as the ••• menu's Share… opens it), Invite people…
// (`agent.share.invite`, the Invite People sheet) and an x. It sits in the one notice slot over the
// composer at the hint tier, so an error or a running step draws first.
//
// Motion: it opens and closes its own height on the house settle (--cmux-ease-settle over
// --cmux-motion-settle), so the transcript over it moves with it in one glide instead of jumping a
// line. Under Reduce Motion (or motion off) both are instant. Stop conditions: the close ends on
// its animation's end, or at once when no animation runs; unmount ends it either way.
import { useEffect, useRef, useState } from "react";
import { useT } from "../i18n";
import { Notice } from "../NoticeSlot";
import "./shareNudge.css";

/** The shipped line, and the gallery's two alternatives (ShareNudge.gallery.tsx). */
export type ShareNudgeLook = "line" | "card" | "reply";

const motionOff = () => {
  try {
    const root = document.documentElement.dataset;
    if (root.cmuxMotion === "off" || root.cmuxMotion === "reduced" || root.agentMotion === "off") return true;
    return globalThis.matchMedia?.("(prefers-reduced-motion: reduce)").matches === true;
  } catch {
    return true;
  }
};

export function ShareNudge({
  open,
  look = "line",
  onShare,
  onInvite,
  onDismiss,
}: {
  open: boolean;
  look?: ShareNudgeLook;
  onShare(): void;
  onInvite(): void;
  onDismiss(): void;
}) {
  const t = useT();
  // Kept on screen while it closes, so it folds away instead of vanishing.
  const [present, setPresent] = useState(open);
  const [wasOpen, setWasOpen] = useState(open);
  if (wasOpen !== open) {
    setWasOpen(open);
    if (open) setPresent(true);
    else if (motionOff()) setPresent(false);
  }
  const closing = present && !open;
  // A close while another notice holds the slot has nothing on screen to fold: it ends at once.
  const node = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (closing && !node.current) setPresent(false);
  }, [closing]);
  const lines =
    look === "card" ? (
      <>
        <span className="acpmux-share-nudge__title">{t("shareNudge.title")}</span>
        <span className="acpmux-share-nudge__text">{t("shareNudge.body")}</span>
      </>
    ) : (
      <span className="acpmux-share-nudge__text">{t("shareNudge.text")}</span>
    );
  return (
    <Notice id="share-nudge" tier="hint" when={present}>
      <div
        ref={node}
        className="acpmux-share-nudge"
        data-look={look}
        data-state={closing ? "closing" : "open"}
        onAnimationEnd={(event) => {
          if (closing && event.target === event.currentTarget) setPresent(false);
        }}
      >
        <div className="acpmux-share-nudge__fold">
          <output className="acpmux-share-nudge__row" aria-live="polite">
            {lines}
            <span className="acpmux-share-nudge__actions">
              <button type="button" className="acpmux-share-nudge__action" disabled={closing} onClick={onShare}>
                {t("shareNudge.share")}
              </button>
              <button type="button" className="acpmux-share-nudge__action" disabled={closing} onClick={onInvite}>
                {t("shareNudge.invite")}
              </button>
              <button
                type="button"
                className="acpmux-share-nudge__close"
                aria-label={t("shareNudge.dismiss")}
                title={t("shareNudge.dismiss")}
                disabled={closing}
                onClick={onDismiss}
              >
                <svg viewBox="0 0 16 16" width="12" height="12" aria-hidden="true">
                  <path d="M3.5 3.5l9 9m0-9l-9 9" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" />
                </svg>
              </button>
            </span>
          </output>
        </div>
      </div>
    </Notice>
  );
}
