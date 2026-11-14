// The chat menu's Move to Terminal (Leo 2026-11-12: "an interesting feature is possibly to move you
// from terminal to gui or vice versa"). The chat leaves this pane for a terminal that runs its
// harness's own resume command (`chats.openInTerminal`, the All chats row's Open in Terminal), and
// only one process writes the conversation at a time: the pane first stops the harness process it
// runs (`_acpmux/kill` without purge and with `ifIdle`, so acpmux refuses while a turn, a queued
// prompt, a permission or a tool call is open), and once the terminal is asked for, the tab closes.
// acpmux keeps the chat and its history either way.
//
// The pane does not stay open View Only: acpmux opens a watch of a conversation it already ran as
// that same chat (`hub/adoption.rs` `adopted_session`), never as a watch, so a pane left open would
// start the harness again on its next prompt while the terminal runs it.
import type { Translate } from "../i18n";
import type { ChatMenuItem } from "./chatHeaderToolsModel";

type Row = Exclude<ChatMenuItem, "separator">;

/// The chat index's harness id for a family whose terminal resumes a chat (acpmux
/// `cmux-chat-index` `AdapterKind::id`): Claude Code is `claude-code` there, `claude` in a summary.
const INDEX_HARNESS: Readonly<Record<string, string>> = { claude: "claude-code", codex: "codex" };

/// The key `chats.openInTerminal` takes, `<index harness id>:<harness session id>`, for a chat whose
/// harness has a terminal resume; undefined for any other.
export function terminalChatKey(family: string | undefined, agentSessionId: string | undefined): string | undefined {
  const harness = family ? INDEX_HARNESS[family] : undefined;
  return harness && agentSessionId ? `${harness}:${agentSessionId}` : undefined;
}

export type TerminalMoveChat = {
  /// The chat's acpmux session: none before it starts.
  sessionId: string | undefined;
  /// The summary's family (else its harness) and the harness's own session id.
  family: string | undefined;
  agentSessionId: string | undefined;
  /// This Mac runs the chat (not a peer, an SSH host or a Cloud machine).
  local: boolean;
  /// The app hosts the pane (`hasNativeHost`): it opens the terminal.
  native: boolean;
  /// Quick Chat's panel, which is not a tab.
  quick: boolean;
  /// The chat views a conversation another app runs (View Only): this pane runs nothing to move.
  watching: boolean;
  /// A turn runs: the row is disabled, so a move never cuts it.
  working: boolean;
};

/// Move to Terminal for a started chat on this Mac whose harness resumes in a terminal (Claude Code,
/// Codex); none in Quick Chat, in View Only, or outside the app. Disabled while a turn runs.
export function terminalMoveRow(chat: TerminalMoveChat, move: (key: string) => void, t: Translate): Row | undefined {
  const key = terminalChatKey(chat.family, chat.agentSessionId);
  if (!chat.sessionId || !key || !chat.local || !chat.native || chat.quick || chat.watching) return undefined;
  return {
    key: "moveToTerminal",
    label: t("chatMenu.moveToTerminal"),
    icon: "terminal",
    disabled: chat.working,
    onSelect: () => move(key),
  };
}

export type TerminalMove = {
  /// Stops the harness process the pane runs for the chat (`_acpmux/kill` with `ifIdle`, no purge).
  release: () => Promise<unknown>;
  /// Opens the terminal (`chats.openInTerminal { key }`).
  open: (key: string) => Promise<unknown>;
  /// Closes the chat's tab.
  close: () => void;
  /// The pane still shows the chat the menu was drawn for.
  same: () => boolean;
  /// A toast: why the move did not happen.
  say: (text: string) => void;
};

/// Whether `error` is acpmux's refusal of a conditional stop because the chat has work
/// (`hub/stop_if_idle.rs`: reason `busy`).
function busy(error: unknown): boolean {
  const data = (error as { data?: unknown } | null)?.data;
  return !!data && typeof data === "object" && (data as { reason?: unknown }).reason === "busy";
}

/// Moves the chat to a terminal: release, then open, then close the tab. A refused release opens
/// nothing (the pane still runs the chat); a refused open leaves the tab (the stopped chat starts
/// again here only on its next prompt). A chat switch meanwhile keeps the tab, which shows another
/// chat now.
export async function moveToTerminal(key: string, run: TerminalMove, t: Translate): Promise<boolean> {
  if (!run.same()) return false;
  try {
    await run.release();
  } catch (error) {
    run.say(busy(error) ? t("chatMenu.moveToTerminalBusy") : t("chatMenu.moveToTerminalFailed"));
    return false;
  }
  try {
    await run.open(key);
  } catch {
    run.say(t("chatMenu.moveToTerminalFailed"));
    return false;
  }
  if (run.same()) run.close();
  return true;
}
