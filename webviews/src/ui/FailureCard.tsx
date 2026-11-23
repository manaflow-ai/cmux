// One failure card for everything that stops: a turn, a host or connection, a sign-in, a New Tab start
// (Beyer principles P1 one of each thing, P4 name the specific thing; leo-workspace design/notifications.md).
// A title that names what stopped, a cause line (an exit code or the last line of stderr, cut to one
// line), the one primary button that is the specific fix, and a quiet secondary ("Show log"). Today
// the same job is a card plus button, bare text plus a pill, and underlined links; this is the shape
// they would share. Presentation only: every string and callback comes from the caller, so this adds no
// shipped copy, and nothing ships through it until a surface adopts it behind an experiment.
import { useId, useState } from "react";
import { Button } from "./Button";
import { cx } from "./cx";
import "./controls.css";
import "./failureCard.css";

/** row: no card, a quiet fill, cause inline. card: a bordered card, the cause on its own line.
 * disclosed: a card whose cause waits behind the secondary, which opens it. */
export type FailureCardLayout = "row" | "card" | "disclosed";

export interface FailureAction {
  label: string;
  onSelect?(): void;
  disabled?: boolean;
}

export interface FailureCardProps {
  layout?: FailureCardLayout;
  /** What stopped, named: "Claude Code stopped in “Fix the login bug”". */
  title: string;
  /** Why, in the words the process gave: "Exited with code 137" or stderr's last line. */
  cause?: string;
  /** The specific fix: Sign in, Install Claude Code, Reconnect, Retry. */
  primary: FailureAction;
  /** Quiet, beside the primary: Show log (disclosed layout: opens or closes the cause). */
  secondary?: FailureAction;
  /** Disclosed layout: the secondary's label while the cause is open ("Hide log"). */
  secondaryOpenLabel?: string;
  className?: string;
}

function Mark() {
  return (
    <svg className="ui-failure__mark" viewBox="0 0 16 16" width="16" height="16" aria-hidden="true">
      <circle cx="8" cy="8" r="6.25" fill="none" stroke="currentColor" strokeWidth="1.5" />
      <path d="M8 4.75v3.9M8 10.6v.1" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" />
    </svg>
  );
}

export function FailureCard({
  layout = "card",
  title,
  cause,
  primary,
  secondary,
  secondaryOpenLabel,
  className,
}: FailureCardProps) {
  const [open, setOpen] = useState(false);
  const causeId = useId();
  const disclosed = layout === "disclosed";
  const size = layout === "row" ? "sm" : "md";
  return (
    <div className={cx("ui-failure", className)} data-layout={layout} role="alert">
      <Mark />
      <div className="ui-failure__text">
        <p className="ui-failure__title">{title}</p>
        {cause && !disclosed && <p className="ui-failure__cause">{cause}</p>}
        {cause && disclosed && open && (
          <p className="ui-failure__raw" id={causeId}>
            {cause}
          </p>
        )}
      </div>
      <div className="ui-failure__actions">
        <Button variant="solid" size={size} disabled={primary.disabled} onClick={primary.onSelect}>
          {primary.label}
        </Button>
        {secondary && (
          <Button
            variant="ghost"
            size={size}
            disabled={secondary.disabled}
            aria-expanded={disclosed ? open : undefined}
            aria-controls={disclosed && open ? causeId : undefined}
            onClick={disclosed ? () => setOpen((value) => !value) : secondary.onSelect}
          >
            {disclosed && open && secondaryOpenLabel ? secondaryOpenLabel : secondary.label}
          </Button>
        )}
      </div>
    </div>
  );
}
