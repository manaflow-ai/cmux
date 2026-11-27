// Feature checks for runtime APIs that older hosts lack (the preview harness
// runtime may not have cmux.gesture or the global onCleanup).

/** The current gesture token, or null on a host without gesture tokens. */
export function gesture(): string | null {
  const g = (cmux as { gesture?: () => string | null }).gesture
  return typeof g === "function" ? g.call(cmux) : null
}

/** Call options that carry the gesture token captured in a tap handler. */
export const withGesture = (token: string | null): CmuxCallOptions => (token ? { gesture: token } : {})
