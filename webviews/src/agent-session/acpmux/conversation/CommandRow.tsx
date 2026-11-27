// A command row names the work and opens to the full shell input, output and exit status.
import { useToolRowCount } from "./toolRowCount";
import { useFindReveal } from "./chatFind";
import { memo, useId, useMemo, useState, useContext } from "react";
import { useT } from "../i18n";
import type { AcpmuxActivity } from "../model";
import { commandFolder } from "./commandFolder";
import { menuPartRef } from "./menuParts";
import { ShellBlock } from "./ShellBlock";
import { BackgroundMark } from "./BackgroundMark";
import { PreviewChip } from "./PreviewChip";
import { RunningTime } from "./RunningTime";
import { RunElsewhereBelow, RunElsewhereChip } from "./RunElsewhere";
import { inBackground } from "./runElsewhereModel";
import { ReactionMark } from "./ReactionMark";
import { ApprovedMark } from "./ApprovedMark";
import { RowShimmer } from "./ShimmerText";
import { TerminalSquare, OpenBook } from "./icons";
import { ReadLabel } from "./ReadLabel";
import { readFullPath, readPath } from "./readPath";
import { SessionCwdContext } from "../turnChanges/sessionRows";
import { isRunning, toolDuration } from "./toolGroups";
import { useRowDisclosure } from "./transcriptDisclosureModel";
import { commandLine, commandLook, commandSaid } from "./commandActions";
import { useAnchoredCollapse } from "./useAnchoredCollapse";
import { rowFailed, toolFailure } from "./toolFailure";
import { ToolLabel } from "./ToolVerb";
import { leadingVerb } from "./toolVerbModel";
import { InlineFailureCause, ToolFailureCause } from "./ToolFailureCause";
import { failureWord, useInStep } from "./toolFailureCauseModel";
import { DisclosureChevron } from "./DisclosureChevron";

// direct.ts replaces only the changed item. Keep every expanded sibling out of that stream's
// render/output work; the row's own disclosure, Find and language subscriptions still update it.
export const CommandRow = memo(function CommandRow({ item }: { item: AcpmuxActivity }) {
  const t = useT();
  useToolRowCount(item.tool?.id, item.tool?.kind);
  const step = useInStep();
  const tool = item.tool!;
  // The Verbose transcript view opens the command to its output.
  // Kept under the call's own key, as a lone call's is: grouped with others it keeps the reader's choice.
  const [open, setOpen] = useRowDisclosure(tool.id);
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
  // How long it took, said in its opened Shell card once it ended (RunningTime.tsx says it while it runs).
  const took = running ? undefined : toolDuration(t, tool);
  // Codex marks no command as passed or failed (Lawrence and Lucas, 2026-11-11 standup): the row
  // draws no check and no time once it ends. A failed call's word ("failed", "Exit 1") stays for
  // screen readers only (conversation.css clips it away); the opened Shell block says "Exit code N".
  const tag = tool.background
    ? tool.background.state === "failed"
      ? t("tools.failed")
      : undefined
    : failure && failureWord(t, failure, step);
  // Find counts the line without its leading cd (chatFind.ts), so a line shortened past that is
  // skipped; opened, the Shell block draws it.
  const look = commandLook();
  const short = commandLine(tool.command ?? "", look, !isRunning(tool));
  const whole = short === commandFolder(tool.command ?? "").rest.trim();
  // What the command did, when the table or its description names it (commandActions.ts); the
  // opened Shell block shows the whole line.
  // A shell read of one file (`sed -n …p a.swift`, `cat a.swift`) draws as every harness's read:
  // the book, "Read <file name>", its full path on hover (ReadLabel.tsx).
  const read = tool.description?.trim() || tool.background ? undefined : readPath(tool);
  const said = read ? undefined : commandSaid(t, tool);
  const cwd = useContext(SessionCwdContext);
  // A live command is its own shimmered line, so it needs no "Running" word (Leo, 2026-11-23:
  // "running" doesn't need text). Finished commands keep the reader's localized "Ran" lead.
  const [before = "", after = ""] = running ? [] : t("tools.ranCommand", { command: "\u0000" }).split("\u0000");
  const line = (
    <code className="cv-command__line" data-find-skip={open || !whole || undefined}>
      {short}
    </code>
  );
  // "Ran" in the run's verb column (ToolVerb.tsx), the command after it. A named action's words are
  // not the command, so Find skips them and opens the row to its Shell block instead.
  const called = read ? (
    <span data-find-skip>
      <ReadLabel path={read} full={readFullPath(read, tool, cwd)} t={t} />
    </span>
  ) : said ? (
    <span data-find-skip>
      <ToolLabel text={said} whole={Boolean(tool.description?.trim())} />
    </span>
  ) : (
    <ToolLabel verb={after ? undefined : leadingVerb(before)} subject={line} skip>
      {before && <span data-find-skip>{before}</span>}
      {line}
      {after && <span data-find-skip>{after}</span>}
    </ToolLabel>
  );
  const words = (
    <>
      {called}
      {tool.background && tool.background.state !== "running" && (
        <span className="cv-command__lead" data-find-skip>
          {" · "}
          {t(`bgTask.state.${tool.background.state}`)}
        </span>
      )}
    </>
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
        <span className="cv-tool__icon">{read ? <OpenBook /> : <TerminalSquare />}</span>
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
          {/* The page a background command serves, while it runs (PreviewChip.tsx). */}
          {tool.background?.state === "running" && <PreviewChip toolCallId={tool.id} />}
          {/* From 20 s on, a running command offers another machine (RunElsewhere.tsx). */}
          <RunElsewhereChip
            toolCallId={tool.id}
            kind={tool.kind}
            command={tool.command}
            startedAt={tool.startedAt}
            running={running}
            background={inBackground(tool)}
          />
          <ReactionMark reaction={tool.reaction} />
          {tool.approved && <ApprovedMark />}
          {!foreground && !tag && tool.background && <BackgroundMark background={tool.background} />}
          {/* How long it has run, counting each second (RunningTime.tsx). */}
          {running && <RunningTime startedAt={tool.startedAt} background={!foreground} />}
        </span>
        <DisclosureChevron open={open} />
      </button>
      {/* A call that went on in the background says how it stands there, not why it failed. */}
      {!tool.background && <ToolFailureCause failure={failure} />}
      <RunElsewhereBelow toolCallId={tool.id} command={tool.command} />
      {fold.present && (
        <div {...fold.bodyProps}>
          <ShellBlock
            id={detailsId}
            command={tool.command}
            output={output}
            cut={tool.earlierOutput}
            exitCode={failure?.exitCode ?? tool.exitCode ?? tool.background?.exitCode}
            reveal={reveal}
            live={running}
            took={took}
          />
        </div>
      )}
    </>
  );
});
