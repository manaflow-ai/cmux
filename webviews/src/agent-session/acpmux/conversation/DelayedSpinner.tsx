import { SPINNER_DELAY_MS, useDelayedVisible } from "./useDelayedVisible";
import { Spinner, type SpinnerLook } from "./Spinner";

type DelayedSpinnerProps = {
  size?: number;
  look?: SpinnerLook;
  /// 0 shows it at once (the `hold` arm of cloudStartJustGo).
  delayMs?: number;
};

/// The working mark, drawn only once the wait passed `delayMs`. Before that it holds the same box,
/// empty, so the line it sits in never moves when it shows.
export function DelayedSpinner({ size = 16, look, delayMs = SPINNER_DELAY_MS }: DelayedSpinnerProps) {
  const visible = useDelayedVisible(delayMs);
  if (!visible)
    return (
      <span
        className="cv-spinner-wait"
        data-spinner-wait=""
        style={{ display: "inline-block", width: size, height: size }}
        aria-hidden
      />
    );
  return <Spinner size={size} loading {...(look ? { look } : {})} />;
}
