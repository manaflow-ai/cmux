// One tool call drawn on its own row: its glyph, its title, and, when it has any, its
// output, Shell block or diff below once opened.
import { useFindReveal } from "./chatFind";
import { useContext, useId, useMemo, useState, type ReactNode } from "react";
import { toolFiles } from "../diff";
import { useT, type Translate } from "../i18n";
import type { AcpmuxActivity } from "../model";
import { OpenableImage, ReplyImage } from "../chips/ReplyImage";
import { mediaKind, ReplyMedia } from "../chips/ReplyMedia";
import { pathName } from "../chips/paths";
import { toolImages } from "../toolImages";
import { toolLabel } from "../toolPaths";
import { SessionCwdContext } from "../turnChanges/sessionRows";
import { EditDiff } from "./EditDiff";
import { CopyButton } from "./CopyButton";
import { experimentArm } from "../../../experiments/experiment";
import { hoverActions } from "../../../ui/hoverActions.experiment";
import { menuPartRef } from "./menuParts";
import { ShellBlock } from "./ShellBlock";
import { OutputMore, useOutput } from "./toolOutput";
import { commandFolder, commandSummary } from "./commandSummary";
import {
  AgentFigures,
  ChevronRight,
  Globe,
  Magnifier,
  OpenBook,
  Pencil,
  Plug,
  TerminalSquare,
  ToolGroup,
} from "./icons";
import { agentLabel, isCallId, mcpLabel, toolGlyph, type ToolGlyph } from "./toolKinds";

type Tool = NonNullable<AcpmuxActivity["tool"]>;

/// Row glyphs by what a call does (toolKinds.ts).
export function toolIcon(glyph: ToolGlyph): ReactNode {
  switch (glyph) {
    case "read":
      return <OpenBook />;
    case "edit":
      return <Pencil size={16} strokeWidth={1.1} />;
    case "search":
      return <Magnifier />;
    case "shell":
      return <TerminalSquare />;
    case "web":
      return <Globe size={16} strokeWidth={1.1} />;
    case "agent":
      return <AgentFigures />;
    case "mcp":
      return <Plug />;
    default:
      return <ToolGroup size={16} strokeWidth={1.2} />;
  }
}

/// A row's words: an agent call's task, an MCP call's server and tool, a shell call's summary
/// ("Fetched feat-cmux-next and diffed HEAD~1", else "Ran {command}" without its leading cd),
/// a file call's path; never a call id.
export function rowLabel(tool: Tool, fallback: string, glyph: ToolGlyph, t: Translate, cwd?: string): string {
  if (glyph === "agent") return agentLabel(tool) ?? t("tools.agent");
  if (glyph === "mcp") return mcpLabel(tool) ?? tool.title;
  const named = isCallId(tool.title, tool) ? { ...tool, title: "" } : tool;
  return toolLabel(
    named,
    isCallId(fallback, tool) ? "" : fallback,
    (command) => commandSummary(command, t) ?? t("tools.ranCommand", { command: commandFolder(command).rest }),
    cwd,
  );
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
  const detailsId = useId();
  const tool = item.tool!;
  const hasDiff = Boolean(tool.diffs?.length);
  // Diffed only while open: a closed edit row costs nothing on each transcript update.
  const files = useMemo(() => (open && hasDiff ? toolFiles([tool]) : []), [open, hasDiff, tool]);
  const cwd = useContext(SessionCwdContext);
  const glyph = toolGlyph(tool);
  const label = rowLabel(tool, item.text, glyph, t, cwd);
  const running = tool.status === "pending" || tool.status === "in_progress";
  const failed = tool.status === "failed";
  const body = tool.output?.replace(/\n$/, "");
  // Only a call with a command line is a shell; an MCP call can also say "execute".
  const shell = tool.kind === "execute" && Boolean(tool.command);
  const images = useMemo(() => toolImages(tool), [tool]);
  const content = (
    <>
      <span className="cv-tool__icon" data-kind={glyph}>
        {toolIcon(glyph)}
      </span>
      {/* A shell row's words are its summary; Find counts its command, painted in the opened Shell block. */}
      <span className="cv-tool__text" data-find-skip={shell || undefined}>
        {label}
        {failed && <span className="cv-tool__detail"> {t("tools.failed")}</span>}
      </span>
    </>
  );
  return (
    <>
      {body || shell || hasDiff ? (
        <button
          type="button"
          className={`cv-tool is-toggle${running ? " is-live" : " is-strong"}`}
          aria-expanded={open}
          aria-controls={open ? detailsId : undefined}
          onClick={() => setOpen((value) => !value)}
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
      {images.length > 0 && <ToolImages sources={images} />}
      {open && shell && (
        <ShellBlock id={detailsId} command={tool.command} output={body} exitCode={tool.exitCode} reveal={reveal} />
      )}
      {open && !shell && files.length > 0 && (
        <div id={detailsId}>
          {files.map((file) => (
            <EditDiff key={file.path} file={file} />
          ))}
        </div>
      )}
      {open && !shell && files.length === 0 && body && <ToolOutput id={detailsId} output={body} reveal={reveal} />}
    </>
  );
}

/// A call's output when it is not a shell's: copyable whole from its right-click menu (Copy Output;
/// the `hover-actions` experiment's "all" arm adds a Copy in its corner on hover), the end of a long
/// one shown.
function ToolOutput({ id, output, reveal }: { id: string; output: string; reveal: number }) {
  const t = useT();
  const shown = useOutput(output, reveal);
  return (
    <div id={id} className="cv-tool-output-card" ref={menuPartRef({ output: shown.text })}>
      {experimentArm(hoverActions) === "all" && (
        <CopyButton
          text={shown.text ?? ""}
          label={t("turn.copy")}
          className="cv-codeblock__action cv-tool-output__copy"
        />
      )}
      <pre className="cv-tool-output selectable">
        {shown.cut && (
          <span className="cv-output-cut" aria-hidden="true">
            …{"\n"}
          </span>
        )}
        {shown.shown}
      </pre>
      <OutputMore output={shown} />
    </div>
  );
}

/// The images a call returned or wrote, shown under its row whether or not it is open: a returned
/// image draws at once, a file loads through the host (ReplyImage, ReplyMedia for video and audio),
/// and a click opens the viewer.
function ToolImages({ sources }: { sources: string[] }) {
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
