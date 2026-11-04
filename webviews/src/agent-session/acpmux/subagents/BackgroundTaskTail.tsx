import { useLayoutEffect, useRef } from "react";
import { useT } from "../i18n";
import { TerminalSquare } from "../conversation/icons";
import { Icon } from "../icons/Icon";
import type { CommandLink } from "../session-info/commandRules";
import { tailLines, useLiveBackgroundTaskOutput } from "../conversation/backgroundTaskOutput";
import type { BackgroundCommand } from "../session-info/processes";

const TAIL_LINES = 10;

/// Expanded tray-only preview of a running command: the command as typed (its line shows it in
/// words, session-info/commandRules.ts), its latest output, and what it is about (a pull request or
/// a run, `link`). Its polling lifetime is owned by the row's disclosure, so streaming transcript
/// tokens never reach this component.
export function BackgroundTaskTail({
  command,
  open,
  readOutput = true,
  link,
  onOpenTerminal,
}: {
  command: BackgroundCommand;
  open: boolean;
  /// The host can read its output; without it the tail shows only the command and its link.
  readOutput?: boolean;
  link?: CommandLink;
  onOpenTerminal?: () => void;
}) {
  const t = useT();
  const read = useLiveBackgroundTaskOutput(command.toolCallId, command.processId, open && readOutput);
  const output = tailLines(read.output, TAIL_LINES);
  const outputRef = useRef<HTMLPreElement>(null);
  useLayoutEffect(() => {
    if (open && outputRef.current) outputRef.current.scrollTop = outputRef.current.scrollHeight;
  }, [open, output]);
  if (!open) return null;
  return (
    <div className="acpmux-running-tray__tail" data-running={read.running || undefined}>
      <code className="acpmux-running-tray__command">{command.command}</code>
      {readOutput && (output ? <pre ref={outputRef}>{output}</pre> : <span>{t("bgTask.state.running")}</span>)}
      {link && (
        <a href={link.url} target="_blank" rel="noreferrer">
          <Icon name="link.external" size={12} row />
          {t("commandRules.openLink")}
        </a>
      )}
      {onOpenTerminal && (
        <button type="button" onClick={onOpenTerminal}>
          <TerminalSquare />
          {t("shell.openInTerminal")}
        </button>
      )}
    </div>
  );
}
