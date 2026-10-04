// One command in a "Ran N commands" group: the command line in mono, cut to the row, then its
// exit status and run time, opening to its Shell block.
import { useState } from "react";
import { useT } from "../i18n";
import type { AcpmuxActivity } from "../model";
import { ShellBlock } from "./ShellBlock";
import { Check, ChevronRight, Spinner } from "./icons";
import { isFailed, isRunning, toolDuration } from "./toolGroups";

export function CommandRow({ item }: { item: AcpmuxActivity }) {
  const t = useT();
  const [open, setOpen] = useState(false);
  const tool = item.tool!;
  const running = isRunning(tool);
  const failed = isFailed(tool);
  const duration = toolDuration(t, tool);
  const exited = tool.exitCode !== undefined && tool.exitCode !== 0;
  return (
    <>
      <button
        type="button"
        className={`cv-tool cv-command is-toggle${running ? " is-live" : " is-strong"}`}
        aria-expanded={open}
        title={tool.command}
        onClick={() => setOpen((value) => !value)}
      >
        <code className="cv-command__line">{tool.command}</code>
        <span className="cv-command__meta">
          {running ? (
            <Spinner size={12} />
          ) : failed ? (
            <span className="cv-command__failed">
              {exited ? t("tools.exit", { code: tool.exitCode! }) : t("tools.failed")}
            </span>
          ) : (
            <Check size={14} className="cv-command__ok" />
          )}
          {duration && <span className="cv-command__time">{duration}</span>}
        </span>
        <ChevronRight
          size={14}
          strokeWidth={1.2}
          className={`cv-tool__chevron cv-rotor${open ? " is-open" : " is-hover"}`}
        />
      </button>
      {open && <ShellBlock command={tool.command} output={tool.output?.replace(/\n$/, "")} exitCode={tool.exitCode} />}
    </>
  );
}
