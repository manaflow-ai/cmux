import type { AcpmuxSnapshot } from "./model";
import type { StringKey } from "./i18n";

export type AuthState = "signedIn" | "signedOut" | "expired" | "needsLogin" | "missing" | "unknown";

export type HarnessAuth = {
  state: AuthState;
  login?: string;
  source?: "harness" | "account" | "migration";
  error?: string;
};

export type AuthPreflight =
  | { state: "ready" }
  | {
      state: Exclude<AuthState, "signedIn" | "unknown">;
      source: "harness" | "account" | "migration";
      login?: string;
      error?: string;
    }
  | { state: "unreachable"; source: "peer"; peer?: string; error?: string };

export type AuthPreflightInput = {
  harness?: string;
  auth?: Readonly<Record<string, HarnessAuth>>;
  summary?: Pick<NonNullable<AcpmuxSnapshot["summary"]>, "harness" | "authState" | "peer">;
  origin?: AcpmuxSnapshot["origin"];
  peerStates?: Readonly<Record<string, string>>;
  peerConnected?: Readonly<Record<string, boolean>>;
  peerOffline?: boolean;
};

export function authState(value: unknown): AuthState {
  if (
    value === "signedIn" ||
    value === "signedOut" ||
    value === "expired" ||
    value === "needsLogin" ||
    value === "missing"
  )
    return value;
  return "unknown";
}

export function authPreflight(input: AuthPreflightInput): AuthPreflight {
  const peer = input.summary?.peer;
  const peerState = peer ? input.peerStates?.[peer] : undefined;
  const peerDown =
    input.peerOffline === true ||
    (peer !== undefined &&
      ((peerState !== undefined && peerState !== "connected") || input.peerConnected?.[peer] === false));
  if ((input.origin === "peer" || input.origin === "remote") && peerDown)
    return { state: "unreachable", source: "peer", ...(peer ? { peer } : {}) };

  const key = input.harness ?? input.summary?.harness;
  const fromSummary = authState(input.summary?.authState);
  if (fromSummary !== "unknown" && fromSummary !== "signedIn") {
    const source = fromSummary === "missing" ? "migration" : "harness";
    return { state: fromSummary, source };
  }
  const current = key ? input.auth?.[key] : undefined;
  if (current && current.state !== "signedIn" && current.state !== "unknown") {
    return {
      state: current.state,
      source: current.source ?? "harness",
      ...(current.login ? { login: current.login } : {}),
      ...(current.error ? { error: current.error } : {}),
    };
  }
  return { state: "ready" };
}

export function authBlockReason(result: AuthPreflight): { reason: StringKey; text: string } | undefined {
  if (result.state === "ready") return undefined;
  if (result.state === "unreachable")
    return { reason: "composer.remoteUnavailable", text: "This machine is unreachable. Reconnect it before sending." };
  const subject = result.source === "account" ? "This account" : "This harness";
  if (result.state === "signedOut")
    return { reason: "harnesses.signedOut", text: subject + " is signed out. Sign in before sending." };
  if (result.state === "expired")
    return { reason: "harnesses.signedOut", text: subject + " session expired. Re-authenticate before sending." };
  if (result.state === "needsLogin")
    return { reason: "harnesses.signedOut", text: subject + " needs you to sign in before sending." };
  return {
    reason: "harnesses.signedOut",
    text:
      result.source === "migration"
        ? "Credentials were lost during migration. Sign in again before sending."
        : subject + " credentials store is unavailable. Sign in again before sending.",
  };
}
