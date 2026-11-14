// A background command rendered as a card, as Claude Desktop's Background tasks panel draws one, in
// place of a bare terminal tab (Leo, 2026-11-07: "only showing the terminal thing, I don't think is
// very useful ... They have it as a properly rendered thing"). Its head is the task's title, its
// time and its Stop; open, its body is the full command in mono, wrapped and never cut to one line,
// then the end of what it printed, streaming while it runs ("No output yet" until it prints), then
// Open in terminal as a secondary action.
//
// One body serves every surface: the composer hat's expanded row (subagents/BackgroundTaskTail.tsx)
// and the Background tasks panel's command rows (BackgroundTasksPanel.tsx). The output comes from
// the reader the hat already polls (conversation/backgroundTaskOutput.ts `useLiveBackgroundTaskOutput`):
// it reads only while the body is open and the page shows, and stops when the card closes or
// unmounts.
import { useLayoutEffect, useRef, useState, type ReactNode } from "react";
import { useFold } from "../conversation/fold";
import { tailLines, useLiveBackgroundTaskOutput } from "../conversation/backgroundTaskOutput";
import { TerminalSquare } from "../conversation/icons";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import "./backgroundTaskCard.css";

/// How many of the last lines of output a card shows.
const CARD_TAIL_LINES = 12;

/// The command and its latest output, with `children` (the surface's actions) under them. Reads
/// only while `open`; with `readOutput` false (a host that cannot read it) it shows the command alone.
/// A surface that draws its own last line (the hat's time, state and actions on one centre line)
/// passes `foot`, which says "No output yet" itself (`empty`) in place of the body's own line.
export function BackgroundTaskBody({
  command,
  toolCallId,
  processId,
  open,
  readOutput = true,
  foot,
  children,
}: {
  command: string;
  toolCallId?: string;
  processId?: string;
  open: boolean;
  readOutput?: boolean;
  foot?: (empty: boolean) => ReactNode;
  children?: ReactNode;
}) {
  const t = useT();
  const read = useLiveBackgroundTaskOutput(toolCallId, processId, open && readOutput);
  const output = tailLines(read.output, CARD_TAIL_LINES);
  // "No output yet" only where output can come: a process acpmux keeps none for says nothing.
  const empty = readOutput && !output && !read.unavailable;
  const outputRef = useRef<HTMLPreElement>(null);
  // New output keeps the newest line in view.
  useLayoutEffect(() => {
    if (open && outputRef.current) outputRef.current.scrollTop = outputRef.current.scrollHeight;
  }, [open, output]);
  return (
    <div className="acpmux-bg-card__body-inner" data-running={read.running || undefined}>
      <code className="acpmux-bg-card__command">
        <span className="acpmux-bg-card__prompt" aria-hidden="true">
          ${" "}
        </span>
        {command}
      </code>
      {readOutput && output && (
        <pre ref={outputRef} className="acpmux-bg-card__output">
          {output}
        </pre>
      )}
      {foot ? foot(empty) : empty && <p className="acpmux-bg-card__empty">{t("backgroundTasks.noOutputYet")}</p>}
      {children}
    </div>
  );
}

/// One task as a card that folds open in place: its title, time and Stop on the head; the command,
/// its output and Open in terminal in the body. Open by default while it runs, as the reference's
/// running card is.
export function BackgroundTaskCard({
  title,
  command,
  toolCallId,
  processId,
  state,
  time,
  stop,
  defaultOpen,
  openAt,
  readOutput = true,
  onOpenTerminal,
}: {
  title: string;
  command: string;
  toolCallId?: string;
  processId?: string;
  state: string;
  time?: string;
  /// The surface's own Stop (it keeps its column there); none once it ended.
  stop?: ReactNode;
  defaultOpen?: boolean;
  /// A request to open this card (its time, Session Info's row through the panel): each new one opens
  /// it and brings it into view.
  openAt?: number;
  readOutput?: boolean;
  onOpenTerminal?: () => void;
}) {
  const t = useT();
  const [open, setOpen] = useState(openAt !== undefined || (defaultOpen ?? state === "running"));
  const [openedAt, setOpenedAt] = useState(openAt);
  if (openAt !== undefined && openAt !== openedAt) {
    setOpenedAt(openAt);
    setOpen(true);
  }
  const fold = useFold(open);
  const card = useRef<HTMLDivElement>(null);
  // Brought into view once per request, before the paint, so the list never shows it elsewhere first.
  useLayoutEffect(() => {
    if (openAt !== undefined) card.current?.scrollIntoView({ block: "nearest" });
  }, [openAt]);
  return (
    <div
      ref={card}
      className="acpmux-bg-card"
      data-state={state}
      data-open={open || undefined}
      data-focused={openAt !== undefined || undefined}
    >
      <div className="acpmux-bg-card__head">
        <button
          type="button"
          className="acpmux-bg-card__toggle"
          aria-expanded={open}
          title={command}
          onClick={() => setOpen(!open)}
        >
          <span className="acpmux-bg-card__disclosure" aria-hidden="true">
            <Icon name={open ? "disclosure.expanded" : "disclosure.collapsed"} size={12} row />
          </span>
          <span className="acpmux-bg-card__title">{title}</span>
        </button>
        {time !== undefined && <span className="acpmux-bg-card__time">{time}</span>}
        {stop}
      </div>
      {fold.present && (
        <div ref={fold.ref} className="cv-fold acpmux-bg-card__body">
          <BackgroundTaskBody
            command={command}
            toolCallId={toolCallId}
            processId={processId}
            open={open}
            readOutput={readOutput}
          >
            {onOpenTerminal && (
              <div className="acpmux-bg-card__actions">
                <button type="button" className="acpmux-bg-card__action" onClick={onOpenTerminal}>
                  <TerminalSquare />
                  {t("shell.openInTerminal")}
                </button>
              </div>
            )}
          </BackgroundTaskBody>
        </div>
      )}
    </div>
  );
}
