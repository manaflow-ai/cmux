import type { CSSProperties, ReactNode } from "react";
import { waitSpinnerDelayMs } from "../waitSpinnerDelay.experiment";
import { useDelayedVisible } from "./DelayedSpinner";
import { Spinner, type SpinnerLook } from "./Spinner";

type WaitSpinnerProps = {
  size?: number;
  className?: string;
  style?: CSSProperties;
  look?: SpinnerLook;
  /// Accepted for a drop-in swap of `<Spinner loading>`; a wait spinner always spins.
  loading?: boolean;
  /// What shows until the wait passes the delay: the control's own icon where the spinner takes its
  /// place (a fork button keeps its fork glyph), else an empty box the spinner's size, so nothing moves.
  until?: ReactNode;
};

/// The spinner for a wait (resuming, connecting, an action in flight), as opposed to one that marks
/// work running. On the `wait-spinner-delay` experiment's `delayed` arm it draws only once the wait
/// passes 300 ms, so a short wait never flashes one (waitSpinnerDelay.experiment.ts). waitSpinners.test.ts
/// keeps every new pane spinner on this unless it marks running work.
export function WaitSpinner({ size = 16, className, style, look, until }: WaitSpinnerProps) {
  const visible = useDelayedVisible(waitSpinnerDelayMs());
  if (!visible)
    return until !== undefined ? (
      <>{until}</>
    ) : (
      <span
        className="cv-spinner-wait"
        data-spinner-wait=""
        style={{ display: "inline-block", width: size, height: size }}
        aria-hidden
      />
    );
  return (
    <Spinner
      size={size}
      loading
      {...(className ? { className } : {})}
      {...(style ? { style } : {})}
      {...(look ? { look } : {})}
    />
  );
}
