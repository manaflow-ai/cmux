import { useLayoutEffect, useRef } from "react";
import { useT } from "../i18n";
import { TerminalSquare } from "../conversation/icons";
import { tailLines, useLiveBackgroundTaskOutput } from "../conversation/backgroundTaskOutput";
import type { BackgroundCommand } from "../session-info/processes";

const TAIL_LINES = 10;

/// Expanded tray-only preview of a running command. Its polling lifetime is owned by the row's
/// disclosure, so streaming transcript tokens never reach this component.
export function BackgroundTaskTail({
  command,
  open,
  onOpenTerminal,
}: {
  command: BackgroundCommand;
  open: boolean;
  onOpenTerminal?: () => void;
}) {
  const t = useT();
  const read = useLiveBackgroundTaskOutput(command.toolCallId, command.processId, open);
  const output = tailLines(read.output, TAIL_LINES);
  const outputRef = useRef<HTMLPreElement>(null);
  useLayoutEffect(() => {
    if (open && outputRef.current) outputRef.current.scrollTop = outputRef.current.scrollHeight;
  }, [open, output]);
  if (!open) return null;
  return (
    <div className="acpmux-running-tray__tail" data-running={read.running || undefined}>
      {output ? <pre ref={outputRef}>{output}</pre> : <span>{t("bgTask.state.running")}</span>}
      {onOpenTerminal && (
        <button type="button" onClick={onOpenTerminal}>
          <TerminalSquare />
          {t("shell.openInTerminal")}
        </button>
      )}
    </div>
  );
}
