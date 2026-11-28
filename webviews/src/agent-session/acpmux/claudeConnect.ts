import { createContext, useContext } from "react";
import { isClaudeToken, normalizeClaudeToken } from "../shared/claudeSetupToken";
import { cloudSetupAction, type CloudSetupAction, type CloudSetupNeed } from "./cloudSetup";

/// What the host gives the composer for a Claude connection. Absent (no provider): the pane cannot
/// add one here, and the picker shows no Connect row.
export type ClaudeConnect = {
  /// True while the person has no enabled Claude connection that serves Cloud
  /// (`ModelConnection.servesCloud`): the picker's Claude section then shows the Connect row.
  needed: boolean;
  /// The picker sections the row leads (AgentMark `agentBrand`); absent: Claude's
  /// (`CLAUDE_CONNECT_BRAND`). A Cloud chat's Set up Cloud need names Codex's too (`setupConnect`).
  brands?: readonly string[];
  /// Checks and saves a pasted setup token, with its optional label. Resolves once the connection
  /// is saved; rejects with an Error whose message is the refusal the person reads ("The token was
  /// refused", "This Mac's agent service is unavailable").
  add?(token: string, label?: string): Promise<void>;
  /// Opens the host's setup for this brand when the composer has no inline card.
  open?(brand: string): void;
  /// One click: starts the host's own sign-in (Settings' `connectClaudeToken`, a Cloud chat's
  /// `cloud.setUp`). Resolves once it is out; its steps arrive as `progress`. Rejects with the
  /// refusal the card shows.
  begin?(brand: string): Promise<void>;
  /// Where the host's sign-in is: a phase while it runs, the error it ended with, else neither.
  progress?: ConnectProgress;
  /// Withdraws the sign-in `begin` started.
  cancel?(): void;
  /// Saves a pasted API key (trimmed) for the family. Absent: the card offers no key field.
  addKey?(key: string): Promise<void>;
};

/// A one-click sign-in's step (ModelsState `claudeToken.phase`, ops.ts).
export type ConnectPhase = "starting" | "signing_in" | "saving";

/// The card's progress line: the running phase, or the error the last attempt ended with.
export type ConnectProgress = { phase: ConnectPhase | null; error: string | null };

export const CONNECT_IDLE: ConnectProgress = { phase: null, error: null };

/// The brand (AgentMark `agentBrand`) of Codex's picker section.
export const CODEX_CONNECT_BRAND = "openai";

/// The picker entry for a held Cloud send. Both setup surfaces resume the same send.
export function setupConnect(
  need: CloudSetupNeed | undefined,
  waiting: boolean,
  run: (action: CloudSetupAction) => void,
  cancel?: () => void,
): ClaudeConnect | undefined {
  if (!need || (need.family !== "claude" && need.family !== "codex")) return undefined;
  const action = cloudSetupAction(need);
  const open = () => {
    if (!waiting) run(action);
  };
  return {
    needed: true,
    brands: [need.family === "codex" ? CODEX_CONNECT_BRAND : CLAUDE_CONNECT_BRAND],
    open,
    // When ChatGPT sign-in is unavailable, open the chosen key setup directly.
    ...(action !== "addKey" && { begin: async () => open() }),
    progress: waiting ? { phase: "signing_in", error: null } : CONNECT_IDLE,
    ...(cancel ? { cancel } : {}),
  };
}

/// The row's muted line for the provider section.
export function connectDetailKey(brand: string | undefined) {
  return brand === CODEX_CONNECT_BRAND
    ? ("composer.envNotConnected" as const)
    : ("picker.connectClaude.detail" as const);
}

export function openClaudeCloudSettings(
  native: (method: string, params: Record<string, unknown>) => Promise<unknown>,
  machine: string,
) {
  return () => void native("cloud.connect", { family: "claude", machine }).catch(() => undefined);
}

export const ClaudeConnectContext = createContext<ClaudeConnect | undefined>(undefined);

export const useClaudeConnect = () => useContext(ClaudeConnectContext);

/// What the picker gets for the Connect row (ModelPickerProps.claudeConnect).
export type ClaudeConnectRowProps = {
  /// The picker sections whose marks match these brands.
  brands: readonly string[];
  /// Saved, and the host has not yet said a connection serves Cloud: the row says Connected.
  connected: boolean;
  /// Opens the inline connect card. The picker closes its menu after calling it.
  onConnect(brand?: string): void;
};

/// The brand (AgentMark `agentBrand`) of the picker section the Connect row leads.
export const CLAUDE_CONNECT_BRAND = "claude";

/// Validation state for the inline card's token field.
export type TokenCheck = "empty" | "valid" | "invalid";

export function checkToken(field: string): TokenCheck {
  const pasted = normalizeClaudeToken(field);
  if (!pasted) return "empty";
  return isClaudeToken(pasted) ? "valid" : "invalid";
}

/// The submit's arguments: the token with all whitespace taken out (`normalizeClaudeToken`), and the
/// label only when one was typed (the app names an unlabeled connection "Claude subscription").
export function connectRequest(token: string, label: string): { token: string; label?: string } {
  const named = label.trim();
  const clean = normalizeClaudeToken(token);
  return named ? { token: clean, label: named } : { token: clean };
}

/// The message the card shows for a failed submit.
export function refusalText(failure: unknown, fallback: string): string {
  const message = failure instanceof Error ? failure.message.trim() : "";
  return message || fallback;
}
