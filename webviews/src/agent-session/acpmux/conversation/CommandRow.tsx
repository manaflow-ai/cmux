// One command in a "Ran N commands" group, as the Codex desktop app lists them: the terminal glyph
// and "Ran <command>" with the command in mono, cut to the row, then its exit status and run time,
// opening to its Shell block.
import { useFindReveal } from "./chatFind";
import { useId, useMemo } from "react";
import { useT } from "../i18n";
import type { AcpmuxActivity } from "../model";
import { menuPartRef } from "./menuParts";
import { ShellBlock } from "./ShellBlock";
import { Check, ChevronRight, Spinner, TerminalSquare } from "./icons";
import { isFailed, isRunning, toolDuration } from "./toolGroups";
import { useTranscriptDisclosure } from "./transcriptDisclosure";

export function CommandRow({ item }: { item: AcpmuxActivity }) {
  const t = useT();
  const tool = item.tool!;
  const [open, setOpen] = useTranscriptDisclosure(`command:${tool.id}`);
  useFindReveal(
    useMemo(() => [item], [item]),
    () => setOpen(true),
  );
  const detailsId = useId();
  const running = isRunning(tool);
  const failed = isFailed(tool);
  const duration = toolDuration(t, tool);
  const exited = tool.exitCode !== undefined && tool.exitCode !== 0;
  // "Ran {command}" in the reader's language, the command drawn as code where the string puts it.
  const [before = "", after = ""] = t("tools.ranCommand", { command: "\u0000" }).split("\u0000");
  return (
    <>
      <button
        type="button"
        className={`cv-tool cv-command is-toggle${running ? " is-live" : " is-strong"}`}
        aria-expanded={open}
        aria-controls={open ? detailsId : undefined}
        ref={menuPartRef({ command: tool.command, output: tool.output?.replace(/\n$/, "") })}
        onClick={() => setOpen((value) => !value)}
      >
        <span className="cv-tool__icon">
          <TerminalSquare />
        </span>
        <span className="cv-command__text">
          {before && <span data-find-skip>{before}</span>}
          <code className="cv-command__line" data-find-skip={open || undefined}>
            {tool.command}
          </code>
          {after && <span data-find-skip>{after}</span>}
        </span>
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
      {open && (
        <ShellBlock
          id={detailsId}
          command={tool.command}
          output={tool.output?.replace(/\n$/, "")}
          exitCode={tool.exitCode}
        />
      )}
    </>
  );
}
