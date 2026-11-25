// The chat's Connect your Claude subscription (cmux-tui/docs/model-connections.md, Revision 2): with
// no Claude connection that serves Cloud, the model picker's Claude section leads with a Claude Code
// row and its Connect button, which opens ClaudeConnectDialog. The pasted token goes to the host
// through `ClaudeConnect.add`, the same gesture as Settings > Models' `addClaudeToken` (ops.ts):
// the app checks it, moves it into the Keychain and hands acpmux only the reference
// (`_acpmux/connections/claude_token.add`). The page never keeps the token after it is sent.
import { createContext, useContext } from "react";
import { isClaudeToken } from "../shared/claudeSetupToken";
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
};

/// The brand (AgentMark `agentBrand`) of Codex's picker section.
export const CODEX_CONNECT_BRAND = "openai";

/// The chat page's Connect row from its Set up Cloud need (cloudSetup.ts): the host refused the
/// Cloud start with `cloud_setup_required` because no personal connection serving Cloud and no
/// organization key serves that family (CloudSetup.Snapshot.choice). None while there is no such
/// need: a local chat, a Cloud chat a connection serves, or a set up already waiting
/// (`waiting`, the card's spinner), so a second press cannot replace the wait. Connect runs the
/// card's own first button for the family.
export function setupConnect(
  need: CloudSetupNeed | undefined,
  waiting: boolean,
  run: (action: CloudSetupAction) => void,
): ClaudeConnect | undefined {
  if (!need || waiting) return undefined;
  const codex = need.family === "codex";
  return {
    needed: true,
    brand: codex ? CODEX_CONNECT_BRAND : CLAUDE_CONNECT_BRAND,
    open: () => run(codex ? "connectChatGPT" : "setUpClaude"),
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
  /// Opens the dialog. The picker closes its menu after calling it.
  onConnect(): void;
};

/// The brand (AgentMark `agentBrand`) of the picker section the Connect row leads.
export const CLAUDE_CONNECT_BRAND = "claude";

/// What the dialog's token field holds: nothing yet, a value that reads as a setup token, or one
/// that does not (its inline error; Verify and connect stays off).
export type TokenCheck = "empty" | "valid" | "invalid";

export function checkToken(field: string): TokenCheck {
  const pasted = field.trim();
  if (!pasted) return "empty";
  return isClaudeToken(pasted) ? "valid" : "invalid";
}

/// The submit's arguments: the trimmed token, and the label only when one was typed (the app
/// names an unlabeled connection "Claude subscription").
export function connectRequest(token: string, label: string): { token: string; label?: string } {
  const named = label.trim();
  return named ? { token: token.trim(), label: named } : { token: token.trim() };
}

/// The refusal the dialog shows for a failed submit: the host's own message, else `fallback`.
export function refusalText(failure: unknown, fallback: string): string {
  const message = failure instanceof Error ? failure.message.trim() : "";
  return message || fallback;
}
