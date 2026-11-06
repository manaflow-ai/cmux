// One command in a "Ran N commands" group, as the Codex desktop app lists them: the terminal glyph
// and what it does (Claude Code's Bash description) or "Ran <command>" with the command in mono, cut
// to the row without the setup it starts with (`export PATH=…;`, a leading `cd <folder> &&`, which
// its Shell block names), then its exit status and run time (the check and time on hover only),
// opening to its Shell block. A command that went on in the background shows how it stands there
// instead (BackgroundMark.tsx), and its time once it ends.
import { useFindReveal } from "./chatFind";
import { memo, useId, useMemo, useState } from "react";
import { useT } from "../i18n";
import type { AcpmuxActivity } from "../model";
import { commandFolder } from "./commandFolder";
import { menuPartRef } from "./menuParts";
import { ShellBlock } from "./ShellBlock";
import { BackgroundMark } from "./BackgroundMark";
import { ReactionMark, ReactionReply } from "./ReactionMark";
import { ApprovedMark } from "./ApprovedMark";
import { RowShimmer } from "./ShimmerText";
import { Check, ChevronRight, TerminalSquare } from "./icons";
import { isRunning, toolDuration } from "./toolGroups";
import { useTranscriptDisclosure } from "./transcriptDisclosure";
import { ROW_WIDTH, shortCommand } from "./shortCommand";
import { useAnchoredCollapse } from "./useAnchoredCollapse";
import { rowFailed, toolFailure } from "./toolFailure";
import { leadingVerb, ToolLabel } from "./ToolVerb";
import { failureWord, InlineFailureCause, ToolFailureCause, useInStep } from "./ToolFailureCause";

// direct.ts replaces only the changed item. Keep every expanded sibling out of that stream's
// render/output work; the row's own disclosure, Find and language subscriptions still update it.
export const CommandRow = memo(function CommandRow({ item }: { item: AcpmuxActivity }) {
  const t = useT();
  const step = useInStep();
  const tool = item.tool!;
  // The Verbose transcript view opens the command to its output.
  const [open, setOpen] = useTranscriptDisclosure(`command:${tool.id}`, false, true);
  // Find in Chat counts matches in the whole output, so a command it reveals shows all of it.
  const [reveal, setReveal] = useState(0);
  useFindReveal(
    useMemo(() => [item], [item]),
    () => {
      setOpen(true);
      setReveal((count) => count + 1);
    },
  );
  const fold = useAnchoredCollapse({ open, onOpenChange: setOpen });
  const menuPart = menuPartRef({ command: tool.command, output: tool.output?.replace(/\n$/, "") });
  const detailsId = useId();
  // Running in the foreground; a call that went on in the background shows BackgroundMark instead.
  const foreground = isRunning(tool);
  const running = foreground || tool.background?.state === "running";
  // Failed by its status or a nonzero exit; in the background, by its status (toolFailure.ts rowFailed).
  const failed = rowFailed(tool);
  // Why it failed, in a word at the row's edge and one line under it (toolFailure.ts).
  const failure = useMemo(() => (failed ? toolFailure(tool) : undefined), [failed, tool]);
  // Claude Code says its exit code only in the output ("Exit code 1"): the Shell block says it once.
  const output = (failure?.output ?? tool.output)?.replace(/\n$/, "");
  const duration = toolDuration(t, tool);
  // A failed call says so in a red word right after its title, before its chevron, as Claude Code
  // desktop tags one ("Count the fixture cases Failed ⌄"; Leo, 2026-11-03: "claude code desktop's
  // summarization of tool calls/parsing of them seem kinda good?"). A step of an opened run says
  // "failed" (drawn "Failed", conversation.css `.cv-command > .cv-command__failed`) and its opened Shell block says
  // "Exit code N"; a lone command keeps its "Exit 1". A background command that failed says it too.
  const tag = tool.background
    ? tool.background.state === "failed"
      ? t("tools.failed")
      : undefined
    : failure && failureWord(t, failure, step);
  // Find counts the line without its leading cd (chatFind.ts), so a line shortened past that is
  // skipped; opened, the Shell block draws it.
  const short = shortCommand(tool.command ?? "", ROW_WIDTH);
  const whole = short === commandFolder(tool.command ?? "").rest.trim();
  // "Ran {command}" in the reader's language, the command drawn as code where the string puts it;
  // "Running {command}" until it is done. Its ⌃B hint is the live line's (WorkingFor.tsx, Thinking.tsx).
  const [before = "", after = ""] = t(foreground ? "tools.runningCommand" : "tools.ranCommand", {
    command: "\u0000",
  }).split("\u0000");
  const line = (
    <code className="cv-command__line" data-find-skip={open || !whole || undefined}>
      {short}
    </code>
  );
  const called = tool.description ? (
    // What the command does in a few words (Claude Code's Bash description); the raw line
    // waits in its Shell block, opened.
    // Find counts the command, not this, so it is not highlighted.
    <span data-find-skip>{tool.description}</span>
  ) : (
    // "Ran" in the run's verb column (ToolVerb.tsx), the command after it.
    <ToolLabel verb={after ? undefined : leadingVerb(before)} subject={line} skip>
      {before && <span data-find-skip>{before}</span>}
      {line}
      {after && <span data-find-skip>{after}</span>}
    </ToolLabel>
  );
  // A command that finished in the background reads as Claude Code desktop notes it, "Background
  // command completed" in the rows' muted tone, then what it did in their ink.
  const words =
    tool.background?.state === "completed" ? (
      <>
        <span className="cv-command__lead" data-find-skip>
          {t("bgTask.completedLead")}
        </span>{" "}
        <span className="cv-command__title">{tool.description ? called : line}</span>
      </>
    ) : (
      called
    );
  return (
    <>
      <button
        type="button"
        className={`cv-tool cv-command is-toggle${running ? " is-live" : " is-strong"}`}
        data-tool-id={tool.id}
        aria-expanded={open}
        aria-controls={open ? detailsId : undefined}
        ref={(node) => {
          fold.headerRef(node);
          menuPart(node);
        }}
        onClick={fold.toggle}
      >
        <span className="cv-tool__icon">
          <TerminalSquare />
        </span>
        <span className="cv-command__text">
          {words}
          {/* While it runs, a light band crosses these words (ShimmerText.tsx RowShimmer). */}
          {running && <RowShimmer>{words}</RowShimmer>}
          {!tool.background && <InlineFailureCause failure={failure} />}
        </span>
        {tag && (
          <span className="cv-command__failed" data-find-skip>
            {tag}
          </span>
        )}
        <span className="cv-command__meta">
          <ReactionMark reaction={tool.reaction} />
          {tool.approved && <ApprovedMark />}
          {foreground || tag ? null : tool.background ? (
            <BackgroundMark background={tool.background} />
          ) : failure ? null : (
            <Check size={14} className="cv-command__ok" />
          )}
          {duration && <span className="cv-command__time">{duration}</span>}
        </span>
        <ChevronRight size={14} className={`cv-tool__chevron cv-rotor${open ? " is-open" : " is-hover"}`} />
      </button>
      {/* A call that went on in the background says how it stands there, not why it failed. */}
      {!tool.background && <ToolFailureCause failure={failure} />}
      {fold.present && (
        <div {...fold.bodyProps}>
          <ShellBlock
            id={detailsId}
            command={tool.command}
            output={output}
            exitCode={failure?.exitCode ?? tool.exitCode ?? tool.background?.exitCode}
            reveal={reveal}
            live={running}
          />
          <ReactionReply reaction={tool.reaction} />
        </div>
      )}
    </>
  );
});
