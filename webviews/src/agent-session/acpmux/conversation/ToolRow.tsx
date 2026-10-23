// One tool call drawn on its own row: its glyph, its title, and, when it has any, its
// output, Shell block or diff below once opened.
import { useFindReveal } from "./chatFind";
import { useContext, useId, useMemo, useState, type ReactNode } from "react";
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
import { CopyButton } from "./CopyButton";
import { experimentArm } from "../../../experiments/experiment";
import { hoverActions } from "../../../ui/hoverActions.experiment";
import { menuPartRef } from "./menuParts";
import { ShellBlock } from "./ShellBlock";
import { BackgroundMark } from "./BackgroundMark";
import { toolDuration } from "./toolGroups";
import { OutputMore, previewedOutput, useOutput } from "./toolOutput";
import { useBlockWrap } from "./blockWrap";
import { Lines, lineCount, PreviewMore, SIDEWAYS_SCROLLER, usePreview, useSidewaysRef, WrapButton } from "./BlockParts";
import { cleanText } from "./mcpCalls";
import { useAnchoredCollapse } from "./useAnchoredCollapse";
import { toolResult, type ToolResult } from "./toolResult";
import { Markdown } from "./Markdown";
import { WriteLabel, writeCall } from "./WriteLabel";
import { rowFailed, toolFailure } from "./toolFailure";
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
export function ToolRow({ item }: { item: AcpmuxActivity }) {
  const t = useT();
  const [open, setOpen] = useState(false);
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
  // Failed by its status or a nonzero exit; in the background, by its status (toolFailure.ts rowFailed).
  const failed = rowFailed(tool);
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
  // harness wrapped it in and the context a host injects into it (toolResult.ts), read only while
  // the call is open: a closed row parses nothing.
  // A finished call's envelope images show in its strip instead of its text (toolImages.ts).
  const strip = stripsEnvelopeImages(tool);
  const result = useMemo(
    () => (shell || !tool.output || !fold.present ? undefined : toolResult(tool.output, cleanText, strip)),
    [shell, tool.output, fold.present, strip],
  );
  const body = shell ? tool.output?.replace(/\n$/, "") : result?.text;
  // Whether a closed call has anything to open, read once per output, not on every render.
  const hasOutput = useMemo(() => Boolean(tool.output && cleanText(tool.output).trim()), [tool.output]);
  const opens = shell ? Boolean(body) : hasOutput;
  const images = useMemo(() => toolImages(tool), [tool]);
  const content = (
    <>
      <span className="cv-tool__icon">{toolIcon(tool.kind)}</span>
      <span className="cv-tool__text" data-find-skip={(shell && (open || !drawsCommand)) || undefined}>
        {write ? <WriteLabel tool={tool} write={write} t={t} /> : label}
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
          <BackgroundMark background={background} />
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
  return (
    <>
      {opens || shell || hasDiff ? (
        <button
          type="button"
          className={`cv-tool is-toggle${running ? " is-live" : " is-strong"}`}
          aria-expanded={open}
          aria-controls={open ? detailsId : undefined}
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
        <div className={`cv-tool${running ? " is-live" : " is-strong"}`}>{content}</div>
      )}
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
}

/// A call's output when it is not a shell's: copyable whole from its right-click menu (Copy Output;
/// the `hover-actions` experiment's "all" arm adds a Copy in its corner on hover), the end of a long
/// one shown. Wrap lines sits in its corner on hover; past eight lines it shows its first ones under
/// a fade, with Show all N lines (BlockParts.tsx).
function ToolOutput({ id, result, reveal }: { id: string; result: ToolResult; reveal: number }) {
  const t = useT();
  const raw = useOutput(result.text, reveal);
  const [wrap] = useBlockWrap("output");
  // All the output's lines, though a long one draws only its end until opened.
  const preview = usePreview(lineCount(raw.text), reveal);
  const shown = previewedOutput(raw, preview);
  const body = useSidewaysRef<HTMLPreElement>();
  // A result's own Markdown (an MCP tool's text reply) reads as Markdown, as a reply does.
  if (result.lang === "markdown")
    return (
      <div id={id} className="cv-tool-output-card" ref={menuPartRef({ output: result.text })}>
        <div className="cv-tool-output__box cv-tool-output__markdown selectable">
          {/* Fences stay code: a tool's text never runs a render card or draws a diagram. */}
          <Markdown plainCode>{result.text}</Markdown>
        </div>
      </div>
    );
  return (
    <div id={id} className="cv-tool-output-card" ref={menuPartRef({ output: shown.text })}>
      <div className="cv-tool-output__box">
        <span className="cv-tool-output__actions">
          <WrapButton kind="output" />
          {experimentArm(hoverActions) === "all" && (
            <CopyButton text={shown.text ?? ""} label={t("turn.copy")} className="cv-codeblock__action" />
          )}
        </span>
        <pre
          ref={body}
          className="cv-tool-output selectable"
          data-wrap={wrap}
          data-preview={preview.attribute}
          data-lang={result.lang === "json" ? "json" : undefined}
          {...SIDEWAYS_SCROLLER}
        >
          {shown.cut && (
            <span className="cv-output-cut" aria-hidden="true">
              …{"\n"}
            </span>
          )}
          {shown.shown && <Lines text={shown.shown} />}
        </pre>
      </div>
      <PreviewMore preview={preview} />
      {!preview.long && <OutputMore output={shown} />}
    </div>
  );
}

/// The images a call returned or wrote, shown under its row whether or not it is open: a returned
/// image draws at once, a file loads through the host (ReplyImage, ReplyMedia for video and audio),
/// and a click opens the viewer.
export function ToolImages({ sources }: { sources: string[] }) {
  return (
    <div className="cv-tool-images">
      {sources.map((source) =>
        source.startsWith("data:") ? (
          <OpenableImage key={source} src={source} alt="" />
        ) : mediaKind(source) ? (
          <ReplyMedia key={source} path={source} alt="" />
        ) : (
          <ReplyImage
            key={source}
            src={source}
            alt=""
            fallback={<span className="cv-chip-plain">{pathName(source)}</span>}
          />
        ),
      )}
    </div>
  );
}
