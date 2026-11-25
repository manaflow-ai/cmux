// The chat's Connect your Claude subscription (cmux-tui/docs/model-connections.md, Revision 2): with
// no Claude connection that serves Cloud, the model picker's Claude section leads with a Claude Code
// row and its Connect button, which opens the inline connect card (ConnectCard.tsx) beside the
// picker. The card's one button is `ClaudeConnect.begin`: the app runs `claude setup-token` itself,
// opens the sign-in page in cmux's browser and saves the token it gets back, so nothing is pasted.
// Paste a token instead still goes through `ClaudeConnect.add`, the same gesture as Settings >
// Models' `addClaudeToken` (ops.ts): the app checks it, moves it into the Keychain and hands acpmux
// only the reference (`_acpmux/connections/claude_token.add`). The page never keeps the token.
import { createContext, useContext } from "react";
import { isClaudeToken, normalizeClaudeToken } from "../shared/claudeSetupToken";
import type { CloudSetupAction, CloudSetupNeed } from "./cloudSetup";

/// What the host gives the composer for a Claude connection. Absent (no provider): the pane cannot
/// add one here, and the picker shows no Connect row.
export type ClaudeConnect = {
  /// True while the person has no enabled Claude connection that serves Cloud
  /// (`ModelConnection.servesCloud`): the picker's Claude section then shows the Connect row.
  needed: boolean;
  /// The picker section the row leads (AgentMark `agentBrand`); absent: Claude's
  /// (`CLAUDE_CONNECT_BRAND`). A Cloud chat's Set up Cloud need names Codex's too (`setupConnect`).
  brand?: string;
  /// Checks and saves a pasted setup token, with its optional label. Resolves once the connection
  /// is saved; rejects with an Error whose message is the refusal the person reads ("The token was
  /// refused", "This Mac's agent service is unavailable"). Absent: Connect runs `open` instead.
  add?(token: string, label?: string): Promise<void>;
  /// The host's own way in, run on Connect instead of the in-chat dialog: the chat page's Set up
  /// Cloud button (`cloud.setUp`), which opens Settings > Models > Add a Connection and starts the
  /// refused chat again once a connection serves it.
  open?(): void;
  /// One click: starts the host's own sign-in (Settings' `connectClaudeToken`, a Cloud chat's
  /// `cloud.setUp`). Resolves once it is out; its steps arrive as `progress`. Rejects with the
  /// refusal the card shows. Absent: the card's button runs `open`.
  begin?(): Promise<void>;
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

/// The chat page's Connect row from its Set up Cloud need (cloudSetup.ts): the host refused the
/// Cloud start with `cloud_setup_required` because no personal connection serving Cloud and no
/// organization key serves that family (CloudSetup.Snapshot.choice). None while there is no such
/// need: a local chat or a Cloud chat a connection serves. While a set up waits (`waiting`) the
/// card shows it signing in and offers Cancel (`cancel`), so a second press cannot replace the wait.
/// The card's button runs the family's one click (`setUpClaude`, which the app runs in place as
/// Settings' `connectClaudeToken`, or `connectChatGPT`).
export function setupConnect(
  need: CloudSetupNeed | undefined,
  waiting: boolean,
  run: (action: CloudSetupAction) => void,
  cancel?: () => void,
): ClaudeConnect | undefined {
  if (!need) return undefined;
  const codex = need.family === "codex";
  const action: CloudSetupAction = codex ? "connectChatGPT" : "setUpClaude";
  return {
    needed: true,
    brand: codex ? CODEX_CONNECT_BRAND : CLAUDE_CONNECT_BRAND,
    open: () => run(action),
    begin: async () => run(action),
    progress: waiting ? { phase: "signing_in", error: null } : CONNECT_IDLE,
    ...(cancel ? { cancel } : {}),
  };
}

/// The row's muted line for `brand`'s section: existing copy only (Set up Cloud's ChatGPT way in
/// for Codex), so the row claims nothing the card does not.
export function connectDetailKey(brand: string | undefined) {
  return brand === CODEX_CONNECT_BRAND ? ("cloudSetup.chatgpt" as const) : ("picker.connectClaude.detail" as const);
}

export const ClaudeConnectContext = createContext<ClaudeConnect | undefined>(undefined);

export const useClaudeConnect = () => useContext(ClaudeConnectContext);

/// What the picker gets for the Connect row (ModelPickerProps.claudeConnect).
export type ClaudeConnectRowProps = {
  /// The picker section it leads: the rail entries whose mark (AgentMark `agentBrand`) is this brand.
  brand: string;
  /// Saved, and the host has not yet said a connection serves Cloud: the row says Connected.
  connected: boolean;
  /// Opens the inline connect card. The picker closes its menu after calling it.
  onConnect(): void;
};

/// The brand (AgentMark `agentBrand`) of the picker section the Connect row leads.
export const CLAUDE_CONNECT_BRAND = "claude";

/// What the dialog's token field holds: nothing yet, a value that reads as a setup token, or one
/// that does not (its inline error; Verify and connect stays off).
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

/// The refusal the dialog shows for a failed submit: the host's own message, else `fallback`.
export function refusalText(failure: unknown, fallback: string): string {
  const message = failure instanceof Error ? failure.message.trim() : "";
  return message || fallback;
}
