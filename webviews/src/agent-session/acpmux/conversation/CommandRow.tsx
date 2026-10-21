// One command in a "Ran N commands" group, as the Codex desktop app lists them: the terminal glyph
// and what it does (Claude Code's Bash description) or "Ran <command>" with the command in mono, cut
// to the row without the setup it starts with (`export PATH=…;`), then its exit status and run time (the check and time on hover only), opening to its
// Shell block.
import { useFindReveal } from "./chatFind";
import { useId, useMemo } from "react";
import { useT } from "../i18n";
import type { AcpmuxActivity } from "../model";
import { menuPartRef } from "./menuParts";
import { BackgroundHint } from "./BackgroundHint";
import { ShellBlock } from "./ShellBlock";
import { Check, ChevronRight, Spinner, TerminalSquare } from "./icons";
import { isFailed, isRunning, toolDuration } from "./toolGroups";
import { useTranscriptDisclosure } from "./transcriptDisclosure";
import { shortCommand } from "../toolPaths";

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
          {tool.description ? (
            // What the command does in a few words (Claude Code's Bash description); the raw line
            // waits in its Shell block, opened.
            <span>{tool.description}</span>
          ) : (
            <>
              {before && <span data-find-skip>{before}</span>}
              <code className="cv-command__line" data-find-skip={open || undefined}>
                {shortCommand(tool.command ?? "")}
              </code>
              {after && <span data-find-skip>{after}</span>}
            </>
          )}
        </span>
        <span className="cv-command__meta">
          {running && <BackgroundHint />}
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
