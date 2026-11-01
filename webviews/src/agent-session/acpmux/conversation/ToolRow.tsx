import { WrittenArtifactButtons } from "./writtenArtifacts";
// One tool call drawn on its own row: its glyph, its title, and, when it has any, its
// output, Shell block or diff below once opened.
import { useFindReveal } from "./chatFind";
import { memo, useContext, useId, useLayoutEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { toolFiles } from "../diff";
import { useT } from "../i18n";
import type { AcpmuxActivity } from "../model";
import { OpenableImage, ReplyImage } from "../chips/ReplyImage";
import { mediaKind, ReplyMedia } from "../chips/ReplyMedia";
import { pathName } from "../chips/paths";
import { stripsEnvelopeImages, toolImages } from "../toolImages";
import { toolLabel } from "../toolPaths";
import { ROW_WIDTH, shortCommand } from "./shortCommand";
import { SessionCwdContext } from "../turnChanges/sessionRows";
import { EditDiff } from "./EditDiff";
import { ShellBlock } from "./ShellBlock";
import { BackgroundMark } from "./BackgroundMark";
import { toolDuration } from "./toolGroups";
import { cleanText, mcpCall } from "./mcpCalls";
import { useAnchoredCollapse } from "./useAnchoredCollapse";
import { useRowDisclosure } from "./transcriptDisclosure";
import { toolResult } from "./toolResult";
import { ToolOutput } from "./ToolOutputBody";
import { WriteLabel, writeCall } from "./WriteLabel";
import { ToolLabel } from "./ToolVerb";
import { callOutput, rowFailed, toolFailure } from "./toolFailure";
import { RepoRecoveryCard, repoRecoveryFor } from "./RepoRecoveryCard";
import { failureWord, InlineFailureCause, ToolFailureCause } from "./ToolFailureCause";
import { Check, ChevronRight, Globe, Magnifier, OpenBook, Pencil, TerminalSquare, ToolGroup } from "./icons";

/// ACP tool kinds (`ToolKind`) to row glyphs.
export function toolIcon(kind?: string): ReactNode {
  switch (kind) {
    case "read":
      return <OpenBook />;
    case "edit":
    case "delete":
    case "move":
    case "fileChange":
      return <Pencil size={16} strokeWidth={1.1} />;
    case "search":
      return <Magnifier />;
    case "execute":
      return <TerminalSquare />;
    case "fetch":
      return <Globe size={16} strokeWidth={1.1} />;
    default:
      return <ToolGroup size={16} strokeWidth={1.2} />;
  }
}

/// One tool call. A call with output opens it below; a
/// shell call opens to its Shell block, with the command line even before any output, and an
/// edit opens to its diff.
// Unchanged item snapshots keep their rendered row as another call streams; local state and
// context changes (Find, language, cwd) still reach this component through React's subscriptions.
export const ToolRow = memo(function ToolRow({ item, grouped = false }: { item: AcpmuxActivity; grouped?: boolean }) {
  const t = useT();
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
  const label = toolLabel(
    tool,
    item.text,
    // "Running …" until it is done, "Ran …" after; its ⌃B hint is the live line's (Thinking.tsx).
    (command) => t(foreground ? "tools.runningCommand" : "tools.ranCommand", { command }),
    cwd,
    t(foreground ? "tools.runningUnnamed" : "tools.ranUnnamed"),
  );
  // An MCP call's plain name ("Hub · read chat", toolPaths.ts) leads with its server, not a verb.
  const plainMcp = useMemo(() => label.includes(" · ") && mcpCall(tool) !== undefined, [label, tool]);
  // Failed by its status or a nonzero exit; in the background, by its status (toolFailure.ts rowFailed).
  const recovery = useMemo(() => repoRecoveryFor(tool), [tool]);
  const failed = rowFailed(tool) && !recovery;
  // Why it failed, in a word on the row and one line under it (toolFailure.ts); read only once it failed.
  const failure = useMemo(() => (failed ? toolFailure(tool) : undefined), [failed, tool]);
  // A Write reads as an edit does: "Writing notes.md", then "Wrote notes.md +18" (WriteLabel.tsx).
  const write = writeCall(tool);
  // A shell that went on in the background says how it stands there, and its time once it ended.
  const background = !failed && !foreground && tool.background;
  // A finished call's check and run time, at the row's right edge and only on hover
  // (conversation.css), as on a command row; its failure already says so in the label.
  const duration = foreground ? undefined : toolDuration(t, tool);
  // Only a call with a command line is a shell; an MCP call can also say "execute".
  const shell = tool.kind === "execute" && Boolean(tool.command);
  // Find counts a shell's whole line: a label that is its description or a shortened line is skipped.
  const drawsCommand = !tool.description && shortCommand(tool.command ?? "", ROW_WIDTH) === tool.command?.trim();
  // A shell prints what it printed. Any other call's result is shown without the JSON envelope a
  // harness wrapped it in and the context a host injects into it (toolResult.ts). Memoize the
  // rendered result so the disclosure and its body agree, including image-only envelopes.
  // A finished call's envelope images show in its strip instead of its text (toolImages.ts).
  const strip = stripsEnvelopeImages(tool);
  // A hook's block shows the hook's words, without the harness's "PreToolUse:… hook error:" envelope.
  const source = callOutput(tool, failure);
  const result = useMemo(() => {
    if (shell || !source) return undefined;
    return toolResult(source, cleanText, strip, {
      kind: tool.kind,
      title: tool.title,
      description: tool.description,
    });
  }, [shell, tool.description, tool.kind, source, tool.title, strip]);
  const body = shell ? tool.output?.replace(/\n$/, "") : result?.text;
  const hasDetails = shell || hasDiff || Boolean(result?.text.trim());
  const labelRef = useRef<HTMLSpanElement>(null);
  const [clipped, setClipped] = useState(false);
  const expandable = hasDetails || clipped;
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
  const images = useMemo(() => toolImages(tool), [tool]);
  const content = (
    <>
      <span className="cv-tool__icon">{toolIcon(tool.kind)}</span>
      <span ref={labelRef} className="cv-tool__text" data-find-skip={(shell && (open || !drawsCommand)) || undefined}>
        {write ? <WriteLabel tool={tool} write={write} t={t} /> : <ToolLabel text={label} whole={plainMcp} />}
        {failure && (
          <span className="cv-tool__failed" data-find-skip>
            {" "}
            {failureWord(t, failure)}
          </span>
        )}
        <InlineFailureCause failure={failure} />
      </span>
      {background ? (
        <span className="cv-command__meta cv-tool__meta">
          <BackgroundMark background={background} showActivity={!grouped} />
          {duration && <span className="cv-command__time">{duration}</span>}
        </span>
      ) : (
        !foreground && (
          <span className="cv-command__meta">
            {!failed && <Check size={14} className="cv-command__ok" />}
            {duration && <span className="cv-command__time">{duration}</span>}
          </span>
        )
      )}
    </>
  );
  // A call opens only to details or a clipped label (Leo, ask-486cb2cec3). A fully visible
  // status such as "Wait 60000 ms" with no body is a plain row.
  return (
    <>
      {expandable ? (
        <button
          type="button"
          className={`cv-tool is-toggle${shell ? "" : " is-whole-open"}${running ? " is-live" : " is-strong"}`}
          data-tool-id={tool.id}
          aria-expanded={open}
          aria-controls={open && (shell || files.length > 0 || body) ? detailsId : undefined}
          ref={fold.headerRef}
          onClick={fold.toggle}
        >
          {content}
          <ChevronRight
            size={14}
            strokeWidth={1.2}
            className={`cv-tool__chevron cv-rotor${open ? " is-open" : " is-hover"}`}
          />
        </button>
      ) : (
        <div className={`cv-tool${running ? " is-live" : " is-strong"}`} data-tool-id={tool.id}>
          {content}
        </div>
      )}
      <WrittenArtifactButtons tools={[tool]} />
      {recovery && <RepoRecoveryCard recovery={recovery} />}
      <ToolFailureCause failure={failure} />
      {images.length > 0 && <ToolImages sources={images} />}
      {fold.present && (shell || files.length > 0 || body) && (
        <div {...fold.bodyProps}>
          {shell ? (
            <ShellBlock
              id={detailsId}
              command={tool.command}
              output={failure?.output?.replace(/\n$/, "") ?? body}
              exitCode={failure?.exitCode ?? tool.exitCode}
              reveal={reveal}
              live={running}
            />
          ) : files.length > 0 ? (
            <div id={detailsId}>
              {files.map((file) => (
                <EditDiff key={file.path} file={file} reveal={reveal} />
              ))}
            </div>
          ) : result ? (
            <ToolOutput id={detailsId} result={result} reveal={reveal} />
          ) : null}
        </div>
      )}
    </>
  );
});

/// The images a call returned or wrote, shown under its row whether or not it is open: a returned
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
