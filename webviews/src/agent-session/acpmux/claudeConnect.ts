import { createContext, useContext } from "react";
import { cloudSetupAction, type CloudSetupAction, type CloudSetupNeed } from "./cloudSetup";

/// What the host gives the composer for a Claude connection. Absent (no provider): the pane cannot
/// add one here, and the picker shows no Connect row.
export type ClaudeConnect = {
  /// True while the person has no enabled Claude connection that serves Cloud
  /// (`ModelConnection.servesCloud`): the picker's Claude section then shows the Connect row.
  needed: boolean;
  /// The picker sections the row leads (AgentMark `agentBrand`); absent: Claude's alone
  /// (`CLAUDE_CONNECT_BRAND`). A Cloud chat's Set up Cloud need names Codex's too (`setupConnect`).
  brands?: readonly string[];
  /// The host's own way in, run on Connect instead of the in-chat dialog: the chat page's Set up
  /// Cloud button (`cloud.setUp`), which opens Settings > Cloud > Cloud models and starts the
  /// refused chat again once a connection serves it. `brand` is the section whose row was pressed.
  open(brand: string): void;
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
    brands: [codex ? CODEX_CONNECT_BRAND : CLAUDE_CONNECT_BRAND],
    open: () => run(cloudSetupAction(need)),
  };
}

/// The row's muted line for `brand`'s section.
export function connectDetailKey(brand: string | undefined) {
  return brand === CODEX_CONNECT_BRAND
    ? ("composer.envNotConnected" as const)
    : ("picker.connectClaude.detail" as const);
}

export const ClaudeConnectContext = createContext<ClaudeConnect | undefined>(undefined);

export const useClaudeConnect = () => useContext(ClaudeConnectContext);

/// What the picker gets for the Connect row (ModelPickerProps.claudeConnect).
export type ClaudeConnectRowProps = {
  /// The picker sections it leads: the rail entries whose mark (AgentMark `agentBrand`) is one of these.
  brands: readonly string[];
  /// Saved, and the host has not yet said a connection serves Cloud: the row says Connected.
  connected: boolean;
  /// Opens the way in for the section `brand` (absent: the first). The picker closes its menu after calling it.
  onConnect(brand?: string): void;
};

/// The brand (AgentMark `agentBrand`) of the picker section the Connect row leads.
export const CLAUDE_CONNECT_BRAND = "claude";
