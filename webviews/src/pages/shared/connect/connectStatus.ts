// The connect card's status words and tones, and when a sign-in counts as expiring: pure, so the
// card, the All connections list and their tests share one answer.
import { intl } from "../../../ui/intl";

/** Every state a connection's pill can show. */
export type ConnectStatus =
  /** Not connected yet: the one action is Connect. */
  | "connect"
  /** A sign-in page is open (in the browser or the in-app sheet): waiting for it to come back. */
  | "connecting"
  | "connected"
  /** Connected, but its sign-in lapses soon (`EXPIRING_WITHIN_MS`): Reconnect now. */
  | "expiring"
  /** Its sign-in lapsed or was revoked: Sign in again (Reconnect). */
  | "reauth"
  /** Connected but waiting on the person (its tools changed, it is turned off). */
  | "attention"
  /** This deployment, plan or policy does not offer it: no action, one line why. */
  | "unavailable"
  /** The last attempt failed. */
  | "error";

export type ConnectTone = "quiet" | "accent" | "success" | "warning" | "danger";

export const CONNECT_TONE: Record<ConnectStatus, ConnectTone> = {
  connect: "quiet",
  connecting: "accent",
  connected: "success",
  expiring: "warning",
  reauth: "danger",
  attention: "warning",
  unavailable: "quiet",
  error: "danger",
};

/** The pill's own words for each state (connect catalog keys). */
export const CONNECT_STATUS_KEY: Record<ConnectStatus, string> = {
  connect: "connect.status.connect",
  connecting: "connect.status.connecting",
  connected: "connect.status.connected",
  expiring: "connect.status.expiring",
  reauth: "connect.status.reauth",
  attention: "connect.status.attention",
  unavailable: "connect.status.unavailable",
  error: "connect.status.error",
};

/** How long before a sign-in lapses the card starts offering Reconnect. */
export const EXPIRING_WITHIN_MS = 3 * 24 * 60 * 60 * 1000;

/**
 * A connected connection's state from when its sign-in lapses: `expiring` inside the window,
 * `reauth` once past, else null (not soon, or no date). `expiresAt` is RFC 3339.
 */
export function expiryStatus(expiresAt: string | null | undefined, now = Date.now()): "expiring" | "reauth" | null {
  if (!expiresAt) return null;
  const at = Date.parse(expiresAt);
  if (!Number.isFinite(at)) return null;
  if (at <= now) return "reauth";
  return at - now <= EXPIRING_WITHIN_MS ? "expiring" : null;
}

/** The lapse time in the person's language, short (`Nov 28, 9:00 AM`). */
export function expiryText(expiresAt: string, language?: string): string {
  const at = new Date(expiresAt);
  if (Number.isNaN(at.getTime())) return expiresAt;
  try {
    return intl
      .DateTimeFormat(language, {
        month: "short",
        day: "numeric",
        hour: "numeric",
        minute: "2-digit",
      })
      .format(at);
  } catch {
    return at.toISOString();
  }
}
