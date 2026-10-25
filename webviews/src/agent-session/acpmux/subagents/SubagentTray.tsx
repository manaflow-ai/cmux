// The tray of running work at the foot of the chat (runningTray.ts): a part of the bottom stack
// right above the composer (bottomStack.css), so it never scrolls away with history and the
// transcript keeps its last row above it. It is the one place running background work shows, in a
// turn and between turns. Each running subagent, background command (inspector/processes.ts
// `backgroundCommands`, the process registry's merged with the transcript's) and chat the agent
// started is one line (AgentLine.tsx, the summary card's rows too): its icon in the theme's accent,
// its name, what it does now, how long it has run (ticking) and its state, Running or Waiting. A
// click opens it: a subagent's pane or view (App.tsx `showSubagent`), a command's terminal
// (processTerminal.ts), a chat. A running subagent, and a command the registry lists, keeps its
// stop button. An agent another one spawned sits right under it.
//
// One item is its line alone. Several get a header first, as the Codex and Claude desktop apps
// head their running agents: "2 subagents running · 1 command", the time since the first started
// and a chevron; between turns it says "Running in background · 2 subagents · 1 command". The
// header counts exactly the lines under it: what runs or waits on the person. The chat's subagents
// and the chats its agent started are all "subagents" (Leo 2026-10-21: "SHOULDN'T THIS SAY
// SUBAGENTS?"). What ended stays as compact status cards after them, never counted. A command is
// named by what its call says it does (inspector/processes.ts `commandLabel`), a chat by its title
// and what its turn does now. Up to three lines show under it; more start folded to the header so
// the tray never takes the transcript's room, and the chevron opens them (a list past five lines
// scrolls in place). Its
// glass is the user bubble's: the theme's text at a low strength over the backdrop, with the
// composer's hairline rim.
//
// A line is quiet at rest: no fill of its own inside the tray's glass, so the tray is one box, not
// a box in a box. Hovering a line that opens something fills that whole line, its stop button
// included, to the tray's own edges (one inset), and shows the hand; a line says its kind first
// ("Command", "Subagent") and ends in a chevron. A command's whole shell line is its tooltip; its
// stop button stops only that command (`_acpmux/process/kill`), which the composer's Stop does not
// (that cancels the turn, and the command outlives it), so its tooltip says so. (Leo 2026-10-21 on
// the strip: "why is that even highlighted in the first place? you can click on it to go
// somewhere? is that a command or a subagent?")
import { memo, useId, useState } from "react";
import { formatDuration } from "../conversation/turns";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { arrivalKey, type BackgroundCommand, commandLabel } from "../inspector/processes";
import { StopButton as ProcessStopButton } from "../inspector/TasksSection";
import { STATUS_LABEL, type SubagentStatus, subagentStatus, subagentStatusLabel } from "../summary/SubagentStatusList";
import { AgentLine } from "./AgentLine";
import { BackgroundTaskTail } from "./BackgroundTaskTail";
import { elapsed, StopButton, useNow } from "./SubagentGroup";
import { itemStart, type TrayItem } from "./runningTray";
import type { StartedSession } from "../started/startedSessions";
import type { SubagentTrayPlacement } from "./subagentTrayPlacement";

/// Lines the tray shows under its header without a click.
export const TRAY_OPEN_MAX = 3;

const itemKey = (item: TrayItem): string =>
  item.kind === "command" ? `command:${arrivalKey(item.command)}` : `${item.kind}:${item.id}`;

/// Memoized: App.tsx keeps its props the same while text streams.
export const SubagentTray = memo(function SubagentTray({
  items,
  finished = NO_ITEMS,
  working,
  waiting,
  onOpen,
  onOpenCommand,
  canOpenTerminal = false,
  canReadTail = false,
  onOpenSession,
  stop,
  stopProcess,
  placement = "tray",
}: {
  /// What runs or waits on the person (runningTray.ts `trayItems`): the lines the header counts.
  items: readonly TrayItem[];
  /// What ended (runningTray.ts `finishedTrayItems`), shown as bounded status cards after them.
  finished?: readonly TrayItem[];
  /// A turn runs: the header counts what runs; between turns it says it runs in the background.
  working: boolean;
  /// The subagents waiting on the user (summary/SubagentStatusList.tsx `waitingSubagents`).
  waiting: ReadonlySet<string>;
  /// Shows a subagent (App.tsx `showSubagent`).
  onOpen: (id: string) => void;
  /// Opens a command's terminal, or what shows it where none opens (App.tsx).
  onOpenCommand?: (command: BackgroundCommand) => void;
  /// The local process registry can replay this chat's output in a terminal.
  canOpenTerminal?: boolean;
  /// A connected local process source is available for the expanded tail.
  canReadTail?: boolean;
  /// Opens a chat the agent started (App.tsx `openOfferChat`).
  onOpenSession?: (sessionId: string) => void;
  /// Stops a running subagent, where the harness can.
  stop?: (id: string) => Promise<unknown>;
  /// Stops a registry process (`_acpmux/process/kill`).
  stopProcess?: (processId: string) => Promise<unknown>;
  /// The default is the existing bottom tray; the alternate is fixture/Labs-driven.
  placement?: SubagentTrayPlacement;
}) {
  const t = useT();
  const listId = useId();
  const now = useNow(items.length > 0);
  // The person's choice holds; until then a short list shows and a long one folds.
  const [opened, setOpened] = useState<boolean>();
  const [showFinished, setShowFinished] = useState(false);
  const [openCommands, setOpenCommands] = useState<ReadonlySet<string>>(() => new Set());
  if (items.length === 0 && finished.length === 0) return null;
  const headed = items.length > 1;
  const open = !headed || (opened ?? items.length <= TRAY_OPEN_MAX);
  // Its subagents and the chats it started are one word: subagents.
  const subagents = items.filter((item) => item.kind !== "command").length;
  const commands = items.length - subagents;
  const starts = items.map(itemStart).filter((start): start is number => start !== undefined);
  const title = [
    working ? subagents > 0 && t("subagents.allRunning", { n: subagents }) : t("bgWork.running"),
    !working && subagents > 0 && t("subagents.count", { n: subagents }),
    commands > 0 && t("turn.working.commands", { n: commands }),
  ]
    .filter((part): part is string => typeof part === "string")
    .join(" · ");
  // Keep live and ended cards in one keyed child list. When a task completes, its card moves
  // between groups without remounting, so keyboard focus and the open affordance stay put.
  const cards = [
    ...items.map((item) => <li key={itemKey(item)}>{line(item)}</li>),
    ...finished.slice(0, showFinished ? finished.length : TRAY_OPEN_MAX).map((item) => (
      <li key={itemKey(item)} data-finished="">
        {line(item)}
      </li>
    )),
    ...(finished.length > TRAY_OPEN_MAX
      ? [
          <li key="finished-overflow">
            <button
              type="button"
              className="acpmux-summary-row acpmux-summary-link acpmux-running-tray__finished"
              aria-expanded={showFinished}
              onClick={() => setShowFinished(!showFinished)}
            >
              <span className="acpmux-summary-text">
                {showFinished ? t("summary.showFewer") : t("summary.viewAll", { n: finished.length })}
              </span>
              <Icon name={showFinished ? "disclosure.expanded" : "disclosure.collapsed"} size={12} />
            </button>
          </li>,
        ]
      : []),
  ];
  return (
    <section
      className="acpmux-running-tray"
      aria-label={t("summary.subagents")}
      data-open={open || undefined}
      data-placement={placement}
    >
      {headed && (
        <button
          type="button"
          className="acpmux-summary-row acpmux-summary-link acpmux-running-tray__head"
          aria-expanded={open}
          aria-controls={open ? listId : undefined}
          onClick={() => setOpened(!open)}
        >
          <span className="acpmux-lineage__icon" data-state="running">
            <Icon name="agent.session" size={14} />
          </span>
          <span className="acpmux-summary-text acpmux-running-tray__title">{title}</span>
          {starts.length > 0 && (
            <span className="acpmux-summary-meta acpmux-running-tray__time">
              {formatDuration(Math.max(0, now - Math.min(...starts)))}
            </span>
          )}
          <Icon name={open ? "disclosure.expanded" : "disclosure.collapsed"} size={12} />
        </button>
      )}
      {open && (
        <ul id={listId} className="acpmux-running-tray__list">
          {cards}
        </ul>
      )}
    </section>
  );

  function line(item: TrayItem) {
    if (item.kind === "agent")
      return (
        <AgentLine
          name={item.agent.name}
          detail={item.agent.action ?? item.agent.kind}
          mark={item.agent.harness}
          status={subagentStatus(item.agent, waiting)}
          state={t(subagentStatusLabel(item.agent, waiting))}
          time={formatDuration(elapsed(item.agent, now))}
          depth={item.depth}
          title={item.agent.task}
          label={t("subagents.open", { name: item.agent.name })}
          kind={t("tray.kind.subagent")}
          chevron
          onOpen={() => onOpen(item.agent.id)}
          after={
            stop &&
            item.agent.state === "running" &&
            !item.agent.command && <StopButton agent={item.agent} stop={stop} />
          }
        />
      );
    if (item.kind === "command") {
      const key = itemKey(item);
      return (
        <>
          <AgentLine
            name={commandLabel(item.command)}
            title={item.command.command}
            kind={t("tray.kind.command")}
            chevron
            icon="terminal"
            working
            status="running"
            state={t("subagents.state.running")}
            expanded={canOpenTerminal ? openCommands.has(key) : undefined}
            time={
              item.command.startedAt === undefined
                ? undefined
                : formatDuration(Math.max(0, now - item.command.startedAt))
            }
            onOpen={
              onOpenCommand
                ? () => {
                    setOpenCommands((current) => {
                      const next = new Set(current);
                      if (next.has(key)) next.delete(key);
                      else next.add(key);
                      return next;
                    });
                    onOpenCommand(item.command);
                  }
                : undefined
            }
            after={
              stopProcess &&
              item.command.processId && (
                <ProcessStopButton
                  id={item.command.processId}
                  name={item.command.command}
                  label={t("tray.stopCommand")}
                  stop={stopProcess}
                />
              )
            }
          />
          <BackgroundTaskTail
            command={item.command}
            open={openCommands.has(key) && canReadTail}
            onOpenTerminal={
              canOpenTerminal && onOpenCommand && item.command.toolCallId
                ? () => onOpenCommand(item.command)
                : undefined
            }
          />
        </>
      );
    }
    return (
      <AgentLine
        name={item.session.title}
        detail={item.session.doing}
        kind={t("tray.kind.subagent")}
        chevron
        icon="agent.chat"
        status={SESSION_STATUS[item.session.state]}
        state={t(STATUS_LABEL[SESSION_STATUS[item.session.state]])}
        onOpen={onOpenSession && (() => onOpenSession(item.session.sessionId))}
      />
    );
  }
});

const NO_ITEMS: readonly TrayItem[] = [];

/// A started chat's line: its turn runs, it waits on the person, its turn failed, or it is done.
const SESSION_STATUS: Record<StartedSession["state"], SubagentStatus> = {
  running: "running",
  waiting: "waiting",
  failed: "failed",
  idle: "done",
};
