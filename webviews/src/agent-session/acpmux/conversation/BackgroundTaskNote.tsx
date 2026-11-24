// A background shell's end in the transcript (cx-ncc.84, Claude parity), when the call that started
// it is not in the transcript (a page not loaded): a shell whose call is there ends on that call's
// own "Ran" row instead (BackgroundMark.tsx, direct.ts `markBackgroundCall`). Noted where it ended
// as Claude desktop notes it, "Background task stopped · <reason>: <command>". Its raw command is
// visible in a monospace line, and a no-output task stays a quiet details row,
// with nothing on hover (Leo 2026-10-13).
//
// A click opens it in place, as a command row opens (CommandRow.tsx): the turn's fold motion and
// rotating chevron, the clicked line held where it is (foldAnchor.ts), and under it the Shell card
// every surface draws for a background command (CommandEndCard.tsx): the whole command, its exit
// status, and the end of what it printed, else "No output" or "Output no longer available", as
// acpmux words it (backgroundTaskOutput.ts, hub/command_end.rs); then who ran it, how long, the
// harness's own words on its end and Open in terminal. A note with nothing to show (no command and
// nothing read) does not open (Leo, 2026-11-24, on a card that showed only "Finished": "but i
// couldnt... do anything?"). A click
// never opens anything else (Leo 2026-10-21: it replaced the window with an empty terminal); only
// Open in terminal opens the task's terminal beside the chat (background-task-terminal-DESIGN.md).
//
// It opens in one step, to its final card (Leo, 2026-11-09: "slow and bad loading state here :(").
// The output lives in acpmux's registry, so the note reads it ahead: once it has been drawn a
// moment, and at once on hover, focus or press. A click before that read answers keeps the note
// closed until it does (at most OPEN_HOLD_MS), then opens it whole; it never draws a stub that a
// card replaces later, pushing the rows under it twice.
import { useContext, useEffect, useId, useRef, type KeyboardEvent, type MouseEvent } from "react";
import { useT } from "../i18n";
import type { AcpmuxBackgroundTask } from "../model";
import { openProcessTerminal } from "../processTerminal";
import { useBackgroundTaskOutput } from "./backgroundTaskOutput";
import { useAnchoredCollapse } from "./useAnchoredCollapse";
import { ChevronRight, TerminalSquare } from "./icons";
import { CommandEndCard } from "./CommandEndCard";
import { commandEndShows } from "./commandEnd";
import { shortCommand } from "./shortCommand";
import { useTranscriptDisclosure } from "./transcriptDisclosureModel";
import { useTranscriptReadOnly } from "./readOnly";
import { SubagentNavContext } from "../subagents/subagentGroupModel";
import { commandRead } from "../session-info/commandRules";
import { currentCommandRules } from "../session-info/commandLabelSettings";
import { spanDuration } from "./turns";
import { WithFacts } from "../chips/FactsHoverCard";

/// The longest a click waits for the registry before the note opens with what it has.
export const OPEN_HOLD_MS = 1500;

export function BackgroundTaskNote({ task }: { task: AcpmuxBackgroundTask }) {
  const t = useT();
  // Read only, the owner's terminal is not the reader's to open.
  const readOnly = useTranscriptReadOnly();
  const openSubagent = useContext(SubagentNavContext);
  const { state, reason } = task;
  const [open, setOpen] = useTranscriptDisclosure(`bgtask:${task.toolCallId}`);
  const fold = useAnchoredCollapse({ open, onOpenChange: setOpen });
  const detailsId = useId();
  const { output: read, settled, request } = useBackgroundTaskOutput(task.toolCallId, true);
  // A click waiting on the read: its stop. A second click while it waits takes it back.
  const holding = useRef<(() => void) | undefined>(undefined);
  useEffect(() => () => holding.current?.(), []);
  const onToggle = (event: MouseEvent) => {
    // A drag or a selection on the line is not a click (deliberateClick), held or not.
    if (!fold.deliberate(event)) return;
    // Nothing to show, nothing to open (a read under way may still find something).
    if (!open && settled && !shows) return;
    if (holding.current) {
      holding.current();
      return;
    }
    const reading = open || settled ? undefined : request();
    if (!reading) {
      fold.toggle();
      return;
    }
    let timer: ReturnType<typeof setTimeout> | undefined;
    const stop = () => {
      clearTimeout(timer);
      if (holding.current === stop) holding.current = undefined;
    };
    const go = () => {
      if (holding.current !== stop) return;
      stop();
      fold.setOpen(true);
    };
    holding.current = stop;
    timer = setTimeout(go, OPEN_HOLD_MS);
    void reading.then(go);
  };
  const command = shortCommand(task.command);
  // A call the agent named reads as the tray names it, what it does and then its name ("Waiting 14m ·
  // hold", commandRules.ts), never the bare name: Leo, 2026-11-05, on a note reading "Background
  // command completed hold": "what are you even holding for?". The command as typed stays in the card.
  const named = task.description ? commandRead(t, task, "terminal", currentCommandRules()).label : undefined;
  // A shell that finished or failed reads as Claude Code desktop notes it, "Background command
  // completed" in the rows' muted tone, then the command in the transcript's ink (Leo, 2026-11-03:
  // "claude code desktop's summarization of tool calls/parsing of them seem kinda good?").
  const lead =
    state === "completed"
      ? t("bgTask.completedLead")
      : state === "failed"
        ? t("bgTask.failedLead")
        : state === "stopped"
          ? t("bgTask.state.stopped")
          : undefined;
  // The event's exit code (Codex sends one), else the registry's.
  const exitCode = task.exitCode ?? read.exitCode;
  // What the harness said of its end beyond the row's words: Claude Code's summary, else a reason the
  // row does not already name (it names a stop's).
  const detail = task.summary || reason;
  const owner = task.ownerTitle?.trim();
  const duration =
    task.startedAt !== undefined && task.endedAt !== undefined
      ? spanDuration(t, task.endedAt - task.startedAt)
      : undefined;
  const ownerLink = owner && task.ownerId && openSubagent;
  const ownerProps = ownerLink
    ? {
        role: "link" as const,
        tabIndex: 0,
        "data-deeplink": `#subagent:${task.ownerId}`,
        onClick: (event: MouseEvent) => {
          event.stopPropagation();
          openSubagent(task.ownerId!);
        },
        onKeyDown: (event: KeyboardEvent) => {
          if (event.key === "Enter" || event.key === " ") {
            event.preventDefault();
            event.stopPropagation();
            openSubagent(task.ownerId!);
          }
        },
      }
    : {};
  // What the card shows, acpmux's account of the command (`read.end`) over the note's own event.
  const end = {
    command: task.command || read.end?.command || "",
    state: read.end?.state && read.end.state !== "running" ? read.end.state : state,
    ...(exitCode !== undefined && { exitCode }),
    ...(read.output && { output: read.output, cut: read.cut }),
    ...((read.end?.outputState ?? (read.output ? "printed" : undefined)) && {
      outputState: read.end?.outputState ?? ("printed" as const),
    }),
  };
  const shows = commandEndShows(end);
  const footer = (
    <div className="cv-bgtask__foot">
      {owner && <span className="cv-bgtask__detail">{ownerLink ? <span {...ownerProps}>{owner}</span> : owner}</span>}
      {duration && <span className="cv-bgtask__detail">{duration}</span>}
      {detail && <span className="cv-bgtask__detail">{detail}</span>}
      {task.toolCallId && !readOnly && (
        <button type="button" className="cv-bgtask__open" onClick={() => void openProcessTerminal(task.toolCallId)}>
          <TerminalSquare />
          {t("shell.openInTerminal")}
        </button>
      )}
    </div>
  );
  return (
    <div className="cv-tools">
      <button
        type="button"
        className="cv-tool cv-bgtask is-toggle"
        data-state={state}
        aria-expanded={open}
        aria-controls={open ? detailsId : undefined}
        ref={fold.headerRef}
        onClick={onToggle}
        onPointerEnter={request}
        onPointerDown={request}
        onFocus={request}
      >
        <span className="cv-tool__icon">
          <TerminalSquare />
        </span>
        <span className="cv-tool__text cv-bgtask__text">
          {owner && (
            <>
              <span className="cv-bgtask__owner" {...ownerProps}>
                {owner}
              </span>{" "}
            </>
          )}
          {lead && (
            <>
              <span className="cv-bgtask__state">{lead}</span>{" "}
            </>
          )}
          {named ? (
            <WithFacts facts={[{ value: task.command, code: true }]}>
              {(facts) => (
                <span {...facts} className="cv-bgtask__title">
                  {named}
                </span>
              )}
            </WithFacts>
          ) : (
            <code className="cv-bgtask__command">{task.command || command}</code>
          )}
        </span>
        {(shows || !settled) && (
          <ChevronRight size={14} className={`cv-tool__chevron cv-rotor${open ? " is-open" : " is-hover"}`} />
        )}
      </button>
      {fold.present && (
        <div {...fold.bodyProps}>
          <CommandEndCard id={detailsId} end={end} footer={footer} />
        </div>
      )}
    </div>
  );
}
