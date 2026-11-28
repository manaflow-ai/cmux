// Feature checks for runtime APIs that older hosts lack (the preview harness
// still ships a runtime without the global onCleanup and without cmux.gesture).

/** The current gesture token, or null on a host without gesture tokens. */
export function gesture(): string | null {
  const g = (cmux as { gesture?: () => string | null }).gesture
  return typeof g === "function" ? g.call(cmux) : null
}

/** Registers `fn` with the current reactive owner when the host provides onCleanup. */
export function cleanup(fn: () => void): void {
  const f = (globalThis as { onCleanup?: (fn: () => void) => void }).onCleanup
  if (typeof f === "function") f(fn)
}
