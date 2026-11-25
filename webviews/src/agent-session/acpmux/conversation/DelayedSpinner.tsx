import { useEffect, useState } from "react";
import { Spinner, type SpinnerLook } from "./Spinner";

/// How long a wait runs before its spinner shows (Leo, 2026-11-25, "just go": a spinner only on a
/// real wait). Shorter waits finish before anything draws, so nothing flickers.
export const SPINNER_DELAY_MS = 300;

/// True once `delayMs` has passed since mount; at once when `delayMs` is 0.
export function useDelayedVisible(delayMs: number = SPINNER_DELAY_MS): boolean {
  const [visible, setVisible] = useState(delayMs <= 0);
  useEffect(() => {
    if (delayMs <= 0) {
      setVisible(true);
      return;
    }
    setVisible(false);
    const timer = setTimeout(() => setVisible(true), delayMs);
    return () => clearTimeout(timer);
  }, [delayMs]);
  return visible;
}

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
