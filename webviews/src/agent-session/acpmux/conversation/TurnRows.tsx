// Codex's turn rows for the pane's transcript: the "Worked for" disclosure, tool rows and the
// footer under an answer. Markup and metrics from reference prototype (messages.tsx,
// TurnMessage.tsx); each component takes the pane's row and draws one transcript entry.
import { useContext, useMemo, useState, type ReactNode } from "react";
import { toolFiles } from "../diff";
import type { AcpmuxActivity, AcpmuxRow } from "../model";
import { copyText } from "./clipboard";
import { EditDiff } from "./EditDiff";
import { ShellBlock } from "./ShellBlock";
import { ToolRun } from "./ToolRun";
import { isFoldedRun } from "./toolRunSummary";
import { TurnActionsContext } from "./turnActions";
import { workedLabel } from "./turns";
import { ChevronRight, Copy, Globe, Magnifier, OpenBook, Pencil, TerminalSquare, ToolGroup, TurnFork } from "./icons";

/// The "Worked for 15s" line; it opens the turn's commentary and tool calls.
export function WorkedFor({ row, expanded, onToggle }: { row: AcpmuxRow; expanded: boolean; onToggle: () => void }) {
  return (
    <button type="button" className="cv-worked has-divider is-toggle" aria-expanded={expanded} onClick={onToggle}>
      <span className="cv-worked__label">{workedLabel(row)}</span>
      <ChevronRight
        size={14}
        strokeWidth={1.2}
        className={`cv-worked__chevron cv-rotor${expanded ? " is-open" : ""}`}
      />
    </button>
  );
}

/// ACP tool kinds (`ToolKind`) to Codex's row glyphs.
function toolIcon(kind?: string): ReactNode {
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

/// One tool call. A call with output opens it below, as Codex's command and tool rows do; a
/// shell call opens to its Shell block, with the command line even before any output, and an
/// edit opens to its diff.
function ToolRow({ item }: { item: AcpmuxActivity }) {
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
        {failed && <span className="cv-tool__detail"> failed</span>}
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

const toolItem = (item: AcpmuxActivity, index: number) =>
  item.tool ? (
    <ToolRow key={item.tool.id || index} item={item} />
  ) : (
    <div className="cv-tool cv-thought" key={index}>
      <span className="cv-tool__text">{item.text}</span>
    </div>
  );

/// A run of tool calls and thoughts between two pieces of text. In an ended turn's open "Worked
/// for", two or more calls fold under one summary line (toolRunSummary.ts); a live turn lists each.
export function ToolRows({ row }: { row: AcpmuxRow }) {
  const items = row.items ?? [];
  return (
    <div className="cv-tools">
      {row.settled && isFoldedRun(items) ? <ToolRun items={items} renderItem={toolItem} /> : items.map(toolItem)}
    </div>
  );
}

const clock = new Intl.DateTimeFormat(undefined, { hour: "numeric", minute: "2-digit" });

/// The quiet row under an answer: copy, fork from here (when acpmux serves forks), the time,
/// and why the turn ended when it did not complete. A turn without a "Worked for" line (history paged in mid-turn) says its time
/// and count here instead.
export function TurnFooter({ row }: { row: AcpmuxRow }) {
  const [copied, setCopied] = useState(false);
  const { fork } = useContext(TurnActionsContext);
  const text = row.text;
  const seq = row.seq;
  const failed = row.status === "failed" || row.status === "error";
  return (
    <div className="cv-turn-actions">
      {!row.folded && <span className="cv-turn-summary">{workedLabel(row)}</span>}
      {text && (
        <button
          type="button"
          className="cv-iconbtn"
          aria-label={copied ? "Copied" : "Copy"}
          title={copied ? "Copied" : "Copy"}
          onClick={() =>
            void copyText(text).then(
              () => setCopied(true),
              () => setCopied(false),
            )
          }
        >
          <Copy />
        </button>
      )}
      {fork && seq !== undefined && (
        <button
          type="button"
          className="cv-iconbtn"
          aria-label="Fork from here"
          title="Fork from here"
          onClick={() => fork(seq)}
        >
          <TurnFork />
        </button>
      )}
      {failed && <span className="cv-turn-note">{row.error || "The turn failed"}</span>}
      <time className="cv-turn-time" dateTime={new Date(row.at).toISOString()}>
        {clock.format(row.at)}
      </time>
    </div>
  );
}
