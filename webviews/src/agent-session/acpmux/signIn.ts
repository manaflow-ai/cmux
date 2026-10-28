import { createContext, useContext } from "react";
import type { AccessOffer } from "./accessOffer";

/// The harnesses this Mac's acpmux last found signed out (`_acpmux/harness/health`, cx-ae9eb),
/// by acpmux harness id, each with its login command ("" when acpmux names none). The model
/// picker's rail dims them and offers Log In in place of their models, so a pick never starts a
/// chat that fails on its first turn.
export type SignIn = {
  signedOut: Readonly<Record<string, string>>;
  /// Runs `login` for `harness` in a terminal tab; the pane checks again when it is back.
  logIn(harness: string, login: string): void;
  /// Add API Key… and Add Credits… beside Log In (accessOffer.ts); absent where the pane cannot run them.
  access?: AccessOffer;
};

export const SignInContext = createContext<SignIn | undefined>(undefined);

export const useSignIn = () => useContext(SignInContext);

/// The signed-out rows of a `_acpmux/harness/health` reply, as `SignIn.signedOut`.
export function signedOutHarnesses(rows: readonly unknown[]): Record<string, string> {
  const out: Record<string, string> = {};
  for (const row of rows) {
    const health = row as { id?: unknown; auth?: unknown; login?: unknown } | null;
    if (typeof health?.id !== "string" || health.auth !== "signedOut") continue;
    out[health.id] = typeof health.login === "string" ? health.login : "";
  }
  return out;
}
