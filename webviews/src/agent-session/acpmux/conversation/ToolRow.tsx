import { ToolVisualRow } from "./ToolVisualPreview";
import { useToolRowCount } from "./toolRowCount";
import { WrittenArtifactButtons } from "./writtenArtifacts";
// One tool call drawn on its own row: its glyph, its title, and, when it has any, its
// output (under its input's labeled fields, ToolDetail.tsx), Shell block, diff, or the card of what a
// read or file search found (FileResultCard.tsx) below once opened.
import { useFindReveal } from "./chatFind";
import { memo, useContext, useId, useLayoutEffect, useMemo, useRef, useState } from "react";
import { toolFiles } from "../diff";
import { useT } from "../i18n";
import type { AcpmuxActivity } from "../model";
import { OpenableImage, ReplyImage } from "../chips/ReplyImage";
import { ReplyMedia } from "../chips/ReplyMedia";
import { mediaKind } from "../chips/replyMediaModel";
import { pathName } from "../chips/paths";
import { stripsEnvelopeImages, toolImages } from "../toolImages";
import { toolKind } from "../toolNames";
import { toolLabel } from "../toolPaths";
import { ReadLabel } from "./ReadLabel";
import { readFullPath, readPath } from "./readPath";
import { SessionCwdContext } from "../turnChanges/sessionRows";
import { EditDiff } from "./EditDiff";
import { ShellBlock } from "./ShellBlock";
import { RunningTime } from "./RunningTime";
import { BackgroundMark } from "./BackgroundMark";
import { PreviewChip } from "./PreviewChip";
import { RunElsewhereBelow, RunElsewhereChip } from "./RunElsewhere";
import { inBackground } from "./runElsewhereModel";
import { ReactionMark } from "./ReactionMark";
import { ApprovedMark } from "./ApprovedMark";
import { RowShimmer } from "./ShimmerText";
import { toolDuration } from "./toolGroups";
import { cleanText } from "./mcpCalls";
import { useAnchoredCollapse } from "./useAnchoredCollapse";
import { useRowDisclosure } from "./transcriptDisclosureModel";
import { toolResult } from "./toolResult";
import { ToolOutput } from "./ToolOutputBody";
import { ToolDetail } from "./ToolDetail";
import { ToolWidget } from "./ToolWidget";
import { FileResultCard } from "./FileResultCard";
import { fileCard } from "./fileResults";
import { inputFields, opensToFields } from "./toolInputFields";
import { WriteLabel } from "./WriteLabel";
import { writeCall } from "./writeLabelModel";
import { WebSources } from "./WebSources";
import { fetchedPage, webSources, withoutLinks } from "./webSourceList";
import { ToolLabel } from "./ToolVerb";
import { callOutput, rowFailed, toolFailure } from "./toolFailure";
import { RepoRecoveryCard } from "./RepoRecoveryCard";
import { InlineFailureCause, ToolFailureCause } from "./ToolFailureCause";
import { failureWord, useInStep } from "./toolFailureCauseModel";
import { toolIcon } from "./toolRowModel";
import { repoRecoveryFor } from "./repoRecoveryCardModel";
import { DisclosureChevron } from "./DisclosureChevron";

/// One tool call. A call with output opens it below; a
/// shell call opens to its Shell block, with the command line even before any output, and an
/// edit opens to its diff.
// Unchanged item snapshots keep their rendered row as another call streams; local state and
// context changes (Find, language, cwd) still reach this component through React's subscriptions.
export const ToolRow = memo(function ToolRow({
  item,
  asRun = false,
}: {
  item: AcpmuxActivity;
  /// The call as it was made (a sent message's Raw, SentMessageLine.tsx): a shell reads as its
  /// command line, never as what it did or its description, since Raw is where the line is shown.
  asRun?: boolean;
}) {
  const t = useT();
  useToolRowCount(item.tool?.id, item.tool?.kind);
  const step = useInStep();
  // Closed, or open in the Verbose transcript view.
  const [open, setOpen] = useRowDisclosure(item.tool?.id);
  // Find in Chat counts matches in the whole output, so a call it reveals shows all of it.
  const [reveal, setReveal] = useState(0);
  useFindReveal(
    useMemo(() => [item], [item]),
    () => {
      setOpen(true);
      setReveal((count) => count + 1);
    },
  );
  const fold = useAnchoredCollapse({ open, onOpenChange: setOpen });
  const detailsId = useId();
  const tool = item.tool!;
  const hasDiff = Boolean(tool.diffs?.length);
  // Diffed only while drawn (open, or closing): a closed edit row costs nothing on each transcript update.
  const files = useMemo(() => (fold.present && hasDiff ? toolFiles([tool]) : []), [fold.present, hasDiff, tool]);
  const cwd = useContext(SessionCwdContext);
  const foreground = tool.status === "pending" || tool.status === "in_progress";
  const running = foreground || tool.background?.state === "running";
  let shownCommand: string | undefined;
  const label = toolLabel(
    tool,
    item.text,
    // A live command is its own shimmered line, so it needs no "Running" word (Leo, 2026-11-23:
    // "running" doesn't need text). Finished commands keep the reader's localized "Ran" lead.
    (command) => {
      shownCommand = command;
      return running ? command : t("tools.ranCommand", { command });
    },
    cwd,
    running || asRun ? undefined : t("tools.ranUnnamed"),
    !asRun,
  );
  // Failed by its status or a nonzero exit; in the background, by its status (toolFailure.ts rowFailed).
  const recovery = useMemo(() => repoRecoveryFor(tool), [tool]);
  const failed = rowFailed(tool) && !recovery;
  // Why it failed, in a word on the row and one line under it (toolFailure.ts); read only once it failed.
  const failure = useMemo(() => (failed ? toolFailure(tool) : undefined), [failed, tool]);
  // A Write reads as an edit does: "Writing notes.md", then "Wrote notes.md +18" (WriteLabel.tsx).
  const description = !asRun && tool.description?.trim();
  const write = description ? undefined : writeCall(tool);
  // A shell that went on in the background says how it stands there, and its time once it ended.
  const background = !failed && !foreground && tool.background;
  // How long a finished call took, said in its opened Shell card (a running one's edge counts it,
  // RunningTime.tsx); its row draws no time once it ends (2026-11-11 standup).
  const took = running ? undefined : toolDuration(t, tool);
  // How long a running call has run, at the row's edge, counting each second (RunningTime.tsx).
  const runningTime = running && <RunningTime startedAt={tool.startedAt} background={!foreground} />;
  // Only a call with a command line is a shell; an MCP call can also say "execute".
  const shell = Boolean(tool.command) && (tool.kind === "execute" || tool.kind === "read");
  // Find counts a shell's whole line: a shortened line is skipped.
  // A label that names what the command did draws no command at all (commandActions.ts), even when
  // its words hold it ("Checked git status"), as on a command row (CommandRow.tsx).
  const drawsCommand = shell && shownCommand === tool.command?.trim();
  // A shell prints what it printed. Any other call's result is shown without the JSON envelope a
  // harness wrapped it in and the context a host injects into it (toolResult.ts). Memoize the
  // rendered result so the disclosure and its body agree, including image-only envelopes.
  // A finished call's envelope images show in its strip instead of its text (toolImages.ts).
  const strip = stripsEnvelopeImages(tool);
  // A hook's block shows the hook's words, without the harness's "PreToolUse:… hook error:" envelope.
  // A web search's links show in its sources chip (WebSources.tsx), not again in its body.
  const sources = useMemo(() => webSources(tool), [tool]);
  // A fetch read one page: its card names that page instead of a sources list.
  const fetched = useMemo(() => fetchedPage(tool), [tool]);
  const output = callOutput(tool, failure);
  const source = output && withoutLinks(tool, output);
  const result = useMemo(() => {
    if (shell || !source) return undefined;
    return toolResult(source, cleanText, strip, {
      kind: tool.kind,
      title: tool.title,
      description: tool.description,
    });
  }, [shell, tool.description, tool.kind, source, tool.title, strip]);
  const body = shell ? tool.output?.replace(/\n$/, "") : result?.text;
  // A finished read or file search draws what it found as a card (fileResults.ts, FileResultCard.tsx)
  // in place of its input fields and raw output; a result the card cannot read whole keeps those.
  const card = useMemo(
    () => (shell || failed || !fold.present ? undefined : fileCard(tool, result?.text, cwd)),
    [shell, failed, fold.present, tool, result, cwd],
  );
  // A call whose input opens as fields has details even before (or without) any output (ToolDetail.tsx).
  const hasInput = useMemo(
    () => !shell && opensToFields(tool, failure) && Boolean(inputFields(tool.inputSummary)),
    [shell, tool, failure],
  );
  const hasDetails = shell || hasDiff || Boolean(result?.text.trim()) || hasInput;
  const labelRef = useRef<HTMLSpanElement>(null);
  const [clipped, setClipped] = useState(false);
  // A call that returned or wrote images opens to them (`ToolImages`), as the Codex app's does.
  const images = useMemo(() => toolImages(tool), [tool]);
  // Native reads show a file and its path on hover. A shell read also opens to its command and output.
  const read = description || write || asRun ? undefined : readPath(tool);
  const expandable = shell || (!read && (hasDetails || clipped || images.length > 0));
  // Label-only rows disclose only actual overflow, not a guessed character count. While open,
  // retain the closed measurement so wrapping does not remove the reader's collapse control.
  useLayoutEffect(() => {
    const node = labelRef.current;
    if (hasDetails || open || !node) return;
    const measure = () => setClipped(node.clientWidth > 0 && node.scrollWidth > node.clientWidth);
    measure();
    const Observer = node.ownerDocument.defaultView?.ResizeObserver;
    if (!Observer) return;
    const observer = new Observer(measure);
    observer.observe(node);
    return () => observer.disconnect();
  }, [hasDetails, open, label, expandable]);
  // Any other call opens to its input, one labeled field per argument, over its output
  // (ToolDetail.tsx); read only while drawn, as the diff is.
  const fields = useMemo(
    () => (fold.present && opensToFields(tool, failure) ? inputFields(tool.inputSummary) : undefined),
    [fold.present, tool, failure],
  );
  const code = shownCommand && <code className="cv-command__line">{shownCommand}</code>;
  const [before, after] = code && !running ? t("tools.ranCommand", { command: "\u0000" }).split("\u0000") : [];
  const words = write ? (
    <WriteLabel tool={tool} write={write} t={t} />
  ) : read ? (
    <ReadLabel path={read} full={readFullPath(read, tool, cwd)} t={t} />
  ) : code ? (
    <ToolLabel verb={after ? undefined : before?.trim()} subject={code}>
      {before}
      {code}
      {after}
    </ToolLabel>
  ) : (
    <ToolLabel text={label} whole={Boolean(description)} />
  );
  const content = (
    <>
      <span className="cv-tool__icon">{toolIcon(read ? "read" : toolKind(tool))}</span>
      <span ref={labelRef} className="cv-tool__text" data-find-skip={(shell && (open || !drawsCommand)) || undefined}>
        {words}
        {tool.background && tool.background.state !== "running" && (
          <span className="cv-command__lead" data-find-skip>
            {" · "}
            {t(`bgTask.state.${tool.background.state}`)}
          </span>
        )}
        {/* While it runs, a light band crosses these words (ShimmerText.tsx RowShimmer). */}
        {running && <RowShimmer>{words}</RowShimmer>}
        <InlineFailureCause failure={failure} />
      </span>
      {/* The failure word, for screen readers only (conversation.css clips it away; Codex draws none). */}
      {failure && (
        <span className="cv-tool__failed" data-find-skip>
          {" "}
          {failureWord(t, failure, step)}
        </span>
      )}
      {background ? (
        <span className="cv-command__meta cv-tool__meta">
          {background.state === "running" && <PreviewChip toolCallId={tool.id} />}
          {shell && (
            <RunElsewhereChip
              toolCallId={tool.id}
              kind={tool.kind}
              command={tool.command}
              startedAt={tool.startedAt}
              running={running}
              background={inBackground(tool)}
            />
          )}
          <ReactionMark reaction={tool.reaction} />
          {tool.approved && <ApprovedMark />}
          <BackgroundMark background={background} />
          {runningTime}
        </span>
      ) : foreground && shell && !tool.approved ? (
        // A running shell's edge holds only the offer of another machine, from 20 s on (RunElsewhere.tsx).
        <span className="cv-command__meta cv-tool__meta">
          <RunElsewhereChip
            toolCallId={tool.id}
            kind={tool.kind}
            command={tool.command}
            startedAt={tool.startedAt}
            running={running}
            background={inBackground(tool)}
          />
          {runningTime}
        </span>
      ) : foreground && !tool.approved ? (
        // Any other running call's edge holds only its time, from a few seconds on (RunningTime.tsx).
        <RunningTime startedAt={tool.startedAt} meta />
      ) : (
        <span className="cv-command__meta">
          {shell && running && (
            <RunElsewhereChip
              toolCallId={tool.id}
              kind={tool.kind}
              command={tool.command}
              startedAt={tool.startedAt}
              running={running}
              background={inBackground(tool)}
            />
          )}
          <ReactionMark reaction={tool.reaction} />
          {tool.approved && <ApprovedMark />}
          {/* Codex marks no call as passed or failed, and shows no time once it ends (2026-11-11). */}
          {runningTime}
        </span>
      )}
    </>
  );
  // A call opens only to details or a clipped label (Leo, ask-486cb2cec3). A fully visible
  // status such as "Wait 60000 ms" with no body is a plain row.
  return (
    <>
      {/* The small image at the row's edge stands for the images until the row opens to them. */}
      <ToolVisualRow sources={images} label={label} opened={open}>
        {expandable ? (
          <button
            type="button"
            className={`cv-tool is-toggle${shell ? "" : " is-whole-open"}${running ? " is-live" : " is-strong"}`}
            data-tool-id={tool.id}
            aria-expanded={open}
            aria-controls={
              open && (shell || files.length > 0 || body || fields || images.length > 0) ? detailsId : undefined
            }
            ref={fold.headerRef}
            onClick={fold.toggle}
          >
            {content}
            <DisclosureChevron open={open} />
          </button>
        ) : (
          <div className={`cv-tool${running ? " is-live" : " is-strong"}`} data-tool-id={tool.id}>
            {content}
          </div>
        )}
      </ToolVisualRow>
      <WrittenArtifactButtons tools={[tool]} />
      <WebSources sources={sources} fetched={fetched} />
      {recovery && <RepoRecoveryCard recovery={recovery} />}
      <ToolFailureCause failure={failure} />
      {shell && <RunElsewhereBelow toolCallId={tool.id} command={tool.command} />}
      {/* An installed extension's card for this call (cmux.chat.widget/1), when the daemon routes one. */}
      {!asRun && <ToolWidget tool={tool} />}
      {/* Its images show once the row opens, a small one at its edge until then (ToolVisualRow): a run
          of screenshots stays a list of lines (Lucas, 2026-11-11: "this really really big scroll
          because it has so many images"), as the Codex app's does. */}
      {expandable && fold.present && (shell || files.length > 0 || body || fields || images.length > 0) && (
        <div {...fold.bodyProps}>
          {images.length > 0 && <ToolImages sources={images} />}
          {shell ? (
            <ShellBlock
              id={detailsId}
              command={tool.command}
              output={failure?.output?.replace(/\n$/, "") ?? body}
              cut={tool.earlierOutput}
              exitCode={failure?.exitCode ?? tool.exitCode}
              reveal={reveal}
              live={running}
              took={took}
            />
          ) : files.length > 0 ? (
            <div id={detailsId}>
              {files.map((file) => (
                <EditDiff key={file.path} file={file} reveal={reveal} />
              ))}
            </div>
          ) : card ? (
            <FileResultCard id={detailsId} card={card} reveal={reveal} />
          ) : fields ? (
            <ToolDetail id={detailsId} fields={fields} result={result} reveal={reveal} />
          ) : result ? (
            <ToolOutput id={detailsId} result={result} reveal={reveal} />
          ) : null}
        </div>
      )}
    </>
  );
});

/// The images a call returned or wrote, shown in its opened row (a small one at the row's edge until
/// then, ToolVisualPreview.tsx): a returned
/// image draws at once, a file loads through the host (ReplyImage, ReplyMedia for video and audio),
/// and a click opens the viewer. Images draw in the fixed-shape thumbnail (at most 320px wide), so
/// one that loads never moves the transcript; a file that is not there draws nothing.
export function ToolImages({ sources }: { sources: string[] }) {
  return (
    <div className="cv-tool-images">
      {sources.map((source) =>
        source.startsWith("data:") ? (
          <OpenableImage key={source} src={source} alt="" thumb />
        ) : mediaKind(source) ? (
          <ReplyMedia key={source} path={source} alt="" />
        ) : (
          <ReplyImage
            key={source}
            src={source}
            alt=""
            fallback={<span className="cv-chip-plain">{pathName(source)}</span>}
            thumb
            hideMissing
          />
        ),
      )}
    </div>
  );
}
