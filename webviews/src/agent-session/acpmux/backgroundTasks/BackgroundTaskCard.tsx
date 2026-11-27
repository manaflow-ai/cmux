// A background command rendered as a card, as Claude Desktop's Background tasks panel draws one, in
// place of a bare terminal tab (Leo, 2026-11-07: "only showing the terminal thing, I don't think is
// very useful ... They have it as a properly rendered thing"). Its head is the task's terminal glyph,
// title, time and Stop; open, its body is the chat's own Shell block (conversation/ShellBlock.tsx: the
// `$` prompt and the command's words in their colours, an eight-line output box that follows a running
// command, Wrap and Copy on hover). A command that has printed nothing shows its command alone, with
// no filler line. Open in terminal is an action on the head that shows when the card is hovered or
// focused (Leo, 2026-11-24: "the open in terminal is odd as a behaviour and looks bad to be showing
// all the time").
//
// One body serves every surface: the composer hat's expanded row (subagents/BackgroundTaskTail.tsx)
// and the Background tasks panel's command rows (BackgroundTasksPanel.tsx). The output comes from
// the reader the hat already polls (conversation/backgroundTaskOutput.ts `useLiveBackgroundTaskOutput`):
// it reads only while the body is open and the page shows, and stops when the card closes or
// unmounts.
import { useLayoutEffect, useRef, useState, type ReactNode } from "react";
import { useFold } from "../conversation/fold";
import { useLiveBackgroundTaskOutput } from "../conversation/backgroundTaskOutput";
import { ShellBlock } from "../conversation/ShellBlock";
import { TerminalSquare } from "../conversation/icons";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import "./backgroundTaskCard.css";
import { WithFacts } from "../chips/FactsHoverCard";
import { Tooltip } from "../../../ui/Tooltip";

/// The command and its latest output as the chat's Shell block, with `foot` (the surface's own last
/// line) under it. Reads only while `open`; with `readOutput` false (a host that cannot read it) it
/// shows the command alone.
export function BackgroundTaskBody({
  command,
  toolCallId,
  processId,
  open,
  readOutput = true,
  foot,
}: {
  command: string;
  toolCallId?: string;
  processId?: string;
  open: boolean;
  readOutput?: boolean;
  foot?: ReactNode;
}) {
  const read = useLiveBackgroundTaskOutput(toolCallId, processId, open && readOutput);
  return (
    <div className="acpmux-bg-card__body-inner" data-running={read.running || undefined}>
      <ShellBlock
        command={command}
        output={readOutput ? read.output : undefined}
        cut={read.cut}
        exitCode={read.exitCode}
        live={read.running}
        whole
        footer={foot}
      />
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
        <WithFacts facts={[{ value: command, code: true }]}>
          {(facts) => (
            <button
              {...facts}
              type="button"
              className="acpmux-bg-card__toggle"
              aria-expanded={open}
              onClick={() => setOpen(!open)}
            >
              <span className="acpmux-bg-card__glyph" aria-hidden="true">
                <TerminalSquare size={14} />
              </span>
              <span className="acpmux-bg-card__title">{title}</span>
              <span className="acpmux-bg-card__disclosure" aria-hidden="true">
                <Icon name={open ? "disclosure.expanded" : "disclosure.collapsed"} size={12} row />
              </span>
            </button>
          )}
        </WithFacts>
        {onOpenTerminal && (
          <Tooltip label={t("shell.openInTerminal")}>
            <button
              type="button"
              className="acpmux-bg-card__terminal"
              aria-label={t("shell.openInTerminal")}
              onClick={onOpenTerminal}
            >
              <Icon name="view.tab.trailing" size={14} />
            </button>
          </Tooltip>
        )}
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
          />
        </div>
      )}
    </div>
  );
}
