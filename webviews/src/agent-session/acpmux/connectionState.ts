import { NativeError } from "./nativeError";
import { isHostRefusal } from "./transportErrors";

/** Whether a host handshake failure is a final refusal rather than a missing/restarting daemon. */
export function isTerminalConnectionFailure(error: unknown): boolean {
  if (error instanceof NativeError) {
    if (error.retryable === false) return true;
    if (isHostRefusal(error)) return true;
    if (error.details && typeof error.details === "object" && (error.details as { restartAcpmux?: unknown }).restartAcpmux === true)
      return true;
    if (error.code && /(?:auth|authentication|authorization|security|permission)/i.test(error.code)) return true;
  }
  if (isHostRefusal(error)) return true;
  const code = typeof error === "object" && error !== null ? (error as { code?: unknown }).code : undefined;
  return typeof code === "string" && /(?:auth|authentication|authorization|security|permission)/i.test(code);
}
