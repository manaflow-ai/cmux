export function shouldFocusTerminalFromPointer(pointerType: string | undefined) {
  return pointerType !== "touch";
}

export function shouldAutoFocusTerminal(hasCoarsePointer: boolean, maxTouchPoints: number) {
  return !hasCoarsePointer && maxTouchPoints <= 0;
}

export function shouldSuppressMouseFocusAfterTouch(lastTouchAt: number, now: number, thresholdMs = 800) {
  if (lastTouchAt <= 0) return false;
  if (now < lastTouchAt) return false;
  return now - lastTouchAt <= thresholdMs;
}
