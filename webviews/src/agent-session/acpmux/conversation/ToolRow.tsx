// One tool call drawn on its own row: its glyph, its title, and, when it has any, its
// output, Shell block or diff below once opened.
import { useMemo, useState, type ReactNode } from "react";
import { toolFiles } from "../diff";
import { t } from "../i18n";
import type { AcpmuxActivity } from "../model";
import { EditDiff } from "./EditDiff";
import { ShellBlock } from "./ShellBlock";
import { ChevronRight, Globe, Magnifier, OpenBook, Pencil, TerminalSquare, ToolGroup } from "./icons";

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
  const [open, setOpen] = useState(false);
  const tool = item.tool!;
  const hasDiff = Boolean(tool.diffs?.length);
  // Diffed only while open: a closed edit row costs nothing on each transcript update.
  const files = useMemo(() => (open && hasDiff ? toolFiles([tool]) : []), [open, hasDiff, tool]);
  const label = tool.title || tool.inputSummary || item.text;
  const running = tool.status === "pending" || tool.status === "in_progress";
  const failed = tool.status === "failed";
  const body = tool.output?.replace(/\n$/, "");
  // Only a call with a command line is a shell; an MCP call can also say "execute".
  const shell = tool.kind === "execute" && Boolean(tool.command);
  const content = (
    <>
      <span className="cv-tool__icon">{toolIcon(tool.kind)}</span>
      <span className="cv-tool__text">
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
      {open && shell && <ShellBlock command={tool.command} output={body} exitCode={tool.exitCode} />}
      {open &&
        !shell &&
        (files.length
          ? files.map((file) => <EditDiff key={file.path} file={file} />)
          : body && <pre className="cv-tool-output">{body}</pre>)}
    </>
  );
}
