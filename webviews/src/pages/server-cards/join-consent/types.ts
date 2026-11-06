// The wire of `cmux.joinConsent.*` (CmuxNextServer/AddDevice/JoinConsentCard.swift).

/** The ask's route on the server card page (`#/join-consent`). */
export const JOIN_CONSENT_CARD = "join-consent";

export const JoinConsentOps = {
  status: "cmux.joinConsent.status",
  changes: "cmux.joinConsent.changes",
  /** Closes the ask, writing nothing; the person's own click or key. */
  deny: "cmux.joinConsent.deny",
  /** Grants the asked surface; only the person's own click on the card (never a key or a script). */
  allow: "cmux.joinConsent.allow",
} as const;

export type JoinConsentSurface = "screen" | "control";

export interface JoinConsentStatus {
  /** The refused request the ask shows; null once it is answered. */
  ask: { requester: string; surface: JoinConsentSurface } | null;
  /** Why the last Allow did not take; the ask stays up showing it. */
  error: string | null;
  /** A write is in flight: both buttons are off. */
  writing: boolean;
}
