// Hold to approve's ring, drawn on an allow button while it is held (useHoldToApprove.ts).
import type { HoldControl } from "./useHoldToApprove";
import "./holdButton.css";

/// The ring at an allow button's leading edge: a faint track and an arc that fills with the hold.
export function HoldRing({ hold }: { hold: Pick<HoldControl, "progress" | "phase" | "reduced"> }) {
  return (
    <svg
      className="acpmux-hold-ring"
      viewBox="0 0 16 16"
      aria-hidden="true"
      data-phase={hold.phase}
      data-reduced={hold.reduced ? "" : undefined}
    >
      <circle className="acpmux-hold-ring-track" cx="8" cy="8" r="6" pathLength={1} />
      <circle
        className="acpmux-hold-ring-fill"
        cx="8"
        cy="8"
        r="6"
        pathLength={1}
        strokeDasharray="1 1"
        strokeDashoffset={1 - hold.progress}
      />
    </svg>
  );
}
