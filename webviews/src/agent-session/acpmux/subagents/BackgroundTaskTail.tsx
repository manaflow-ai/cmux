import type { ReactNode } from "react";
import { useT } from "../i18n";
import { TerminalSquare } from "../conversation/icons";
import { Icon } from "../icons/Icon";
import { BackgroundTaskBody } from "../backgroundTasks/BackgroundTaskCard";
import type { CommandLink } from "../session-info/commandRules";
import type { BackgroundCommand } from "../session-info/processes";

/// Expanded tray-only preview of a running command, the shared card's body
/// (backgroundTasks/BackgroundTaskCard.tsx): the whole command as typed, its latest output or "No
/// output yet", then its owner, elapsed time, what it is about (a pull request or a run, `link`) and
/// Open in terminal. Its polling lifetime is owned by the row's disclosure, so streaming transcript
/// tokens never reach this component.
export function BackgroundTaskTail({
  command,
  open,
  readOutput = true,
  link,
  owner,
  elapsed,
  onOpenTerminal,
  onOpenOwner,
}: {
  command: BackgroundCommand;
  open: boolean;
  /// The host can read its output; without it the tail shows only the command and its link.
  readOutput?: boolean;
  link?: CommandLink;
  owner?: string;
  /// Its time (SubagentTray.tsx `commandTime`), ticking in its own leaf while it runs.
  elapsed?: ReactNode;
  onOpenTerminal?: () => void;
  /// Opens the subagent that runs it (`owner`): an explicit button, never the row's click.
  onOpenOwner?: () => void;
}) {
  const t = useT();
  if (!open) return null;
  return (
    <div className="acpmux-running-tray__tail">
      <BackgroundTaskBody
        command={command.command}
        toolCallId={command.toolCallId}
        processId={command.processId}
        open={open}
        readOutput={readOutput}
        foot={(empty) => (
          <>
            {/* One line under the command, on its left edge: its time, "No output yet" while it has printed nothing
              and its actions, all at the detail size on one centre line (Leo, 2026-11-07: "wildly misaligned
              at the bottom"). */}
            {(owner || elapsed || empty || link || onOpenTerminal || onOpenOwner) && (
              <div className="acpmux-running-tray__tail-foot">
                {(owner || elapsed) && (
                  <span className="acpmux-running-tray__meta">
                    {owner}
                    {owner && elapsed ? " · " : ""}
                    {elapsed}
                  </span>
                )}
                {empty && <span className="acpmux-running-tray__meta">{t("backgroundTasks.noOutputYet")}</span>}
                {link && (
                  <a href={link.url} target="_blank" rel="noreferrer">
                    <Icon name="link.external" size={12} row />
                    {t("commandRules.openLink")}
                  </a>
                )}
                {owner && onOpenOwner && (
                  <button type="button" aria-label={t("subagents.open", { name: owner })} onClick={onOpenOwner}>
                    <Icon name="agent.chat" size={12} row />
                    {t("subsession.openChat")}
                  </button>
                )}
                {onOpenTerminal && (
                  <button type="button" onClick={onOpenTerminal}>
                    <TerminalSquare />
                    {t("shell.openInTerminal")}
                  </button>
                )}
              </div>
            )}
          </>
        )}
      />
    </div>
  );
}
