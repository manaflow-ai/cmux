// l10n-allow-file: synthetic fixtures for the gallery, the browser dev loop and the tests, not shipped UI.
import type { JoinConsentStatus } from "./types";

export function askStatus(patch: Partial<JoinConsentStatus> = {}): JoinConsentStatus {
  return { ask: { requester: "studio-mac", surface: "screen" }, error: null, writing: false, ...patch };
}

/** An in-memory `cmux.joinConsent.*` for the browser dev loop (`/server-cards/?mock#/join-consent`):
 * Deny ends the ask at once. Allow is the app panel's native button, so the dev loop has none. */
export class MockJoinConsent {
  status: JoinConsentStatus = askStatus();
  private readonly listeners = new Set<() => void>();

  call(op: string): unknown {
    switch (op) {
      case "cmux.joinConsent.status":
        return this.status;
      case "cmux.joinConsent.deny":
        this.update({ ...this.status, ask: null });
        return null;
      default:
        return undefined;
    }
  }

  subscribe(onEvent: () => void): () => void {
    this.listeners.add(onEvent);
    return () => void this.listeners.delete(onEvent);
  }

  private update(status: JoinConsentStatus) {
    this.status = status;
    for (const listener of this.listeners) listener();
  }
}
