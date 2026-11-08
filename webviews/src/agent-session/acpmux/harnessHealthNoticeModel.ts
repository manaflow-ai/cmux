import { createContext, useContext } from "react";

export function skipped(): Record<string, string> {
  try {
    const value: unknown = JSON.parse(globalThis.localStorage?.getItem(SKIPPED) ?? "{}");
    return value && typeof value === "object" ? (value as Record<string, string>) : {};
  } catch {
    return {};
  }
}

/// One row of acpmux's `_acpmux/harness/health` (cx-ny85), as the host hands it to the pane
/// (`harness.health`).
export type HarnessHealth = {
  id: string;
  version?: string | null;
  latest?: string | null;
  outdated?: boolean;
  /// Only from evidence (a profile's check, or a probe's sign-in error); `expired`: a credential the
  /// check or probe said expired.
  auth?: "signedIn" | "signedOut" | "expired" | "unknown";
  /// The command that signs it in.
  login?: string | null;
  /// How to update it; `elevated`: it needs sudo, so the pane never offers it.
  update?: { command: string; elevated: boolean } | null;
};

/// Whether a health row's sign-in needs the person to log in: signed out, or its credential expired.
export const needsLogin = (auth: HarnessHealth["auth"]): boolean => auth === "signedOut" || auth === "expired";

/// The agent CLI versions the person chose to skip, by harness id (this browser profile).
export const SKIPPED = "cmux.acpmux.skippedUpdates";

export function skip(id: string, version: string): void {
  try {
    globalThis.localStorage?.setItem(SKIPPED, JSON.stringify({ ...skipped(), [id]: version }));
  } catch {
    // No storage (a private window): skipped for this chat only.
  }
}

/// An agent CLI update on offer (hq#2569 #12): never a banner over the chat, and never a dot on the
/// model chip (Leo 2026-10-21). The chip's tooltip names it and its menu and picker offer Update and
/// Skip This Version (`UpdateOfferContext`).
export type UpdateOffer = {
  harness: string;
  agent: string;
  version: string;
  latest: string;
  update(): void;
  skip(): void;
};

export const UpdateOfferContext = createContext<UpdateOffer | undefined>(undefined);

export const useUpdateOffer = () => useContext(UpdateOfferContext);
