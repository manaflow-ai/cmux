import type { ReadSessionAuth, SessionAuth } from "./sessionAuth";
import { createContext, useContext } from "react";

/// The harnesses this Mac's acpmux last found signed out (`_acpmux/harness/health`, cx-ae9eb),
/// by acpmux harness id, each with its login command ("" when acpmux names none). The model
/// picker's rail dims them and offers Log In in place of their models, so a pick never starts a
/// chat that fails on its first turn.
export type SignIn = {
  /** Selected chat/target only; from _acpmux/session/auth, never host-wide health. */
  sessionAuth?: SessionAuth;
  recheckSession?(): void;
  loginSession?(auth?: SessionAuth): void;
  readSessionAuth?: ReadSessionAuth;
  authEpoch?: string | number;
  authRefresh?: number;
  authObservation?: number;
  signedOut: Readonly<Record<string, string>>;
  /// Runs `login` for `harness` in a terminal tab; the pane checks again when it is back.
  logIn(harness: string, login: string): void;
};

export const SignInContext = createContext<SignIn | undefined>(undefined);

export const useSignIn = () => useContext(SignInContext);

/// The signed-out (or expired) rows of a `_acpmux/harness/health` reply, as `SignIn.signedOut`.
export function signedOutHarnesses(rows: readonly unknown[]): Record<string, string> {
  const out: Record<string, string> = {};
  for (const row of rows) {
    const health = row as { id?: unknown; auth?: unknown; login?: unknown } | null;
    if (typeof health?.id !== "string" || (health.auth !== "signedOut" && health.auth !== "expired")) continue;
    out[health.id] = typeof health.login === "string" ? health.login : "";
  }
  return out;
}
