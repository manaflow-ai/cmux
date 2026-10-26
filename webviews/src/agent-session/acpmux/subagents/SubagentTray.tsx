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
// the tray never takes the transcript's room, and the chevron opens them. Its
// glass is the user bubble's: the theme's text at a low strength over the backdrop, with the
// composer's hairline rim.
//
// The header is pinned (Leo 2026-10-25: "the sort of collapse at the top section, like that
// disappears for some reason at the top ... sometimes it disappears"). It went for two reasons: the
// bottom stack made the whole tray its own scroller (bottomStack.css `overflow-y: auto` on every
// part), so in a short pane, or with the list's ended cards, the header scrolled up and out with the
// lines; and it only drew with two running lines, so once one of two ended it unmounted while its
// ended cards stayed. Now the tray is a column that never scrolls: the header on top, then the list
// (running first, then the ones that ended last), the only part that scrolls, then View all,
// pinned at its foot. The header shows whenever the tray has more than one line, running or ended.
// A line says what the agent does now in words (trayDetail.ts), never a raw shell line.
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
import { experimentArm } from "../../../experiments/experiment";
import { formatDuration } from "../conversation/turns";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { arrivalKey, type BackgroundCommand, commandLabel, sendLabel } from "../inspector/processes";
import { StopButton as ProcessStopButton } from "../inspector/TasksSection";
import { STATUS_LABEL, type SubagentStatus, subagentStateText, subagentStatus } from "../summary/SubagentStatusList";
import { retrying, retryLabel, sessionRetry } from "./retryState";
import { AgentLine } from "./AgentLine";
import { BackgroundTaskTail } from "./BackgroundTaskTail";
import { elapsed, StopButton, useNow } from "./SubagentGroup";
import { itemStart, type TrayItem } from "./runningTray";
import { doingDetail, toolDetail } from "./trayDetail";
import { trayPanelLook } from "./trayPanel.experiment";
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
  // Read once per tray: the arm is the gallery's override or a dogfood key, never a per-tick read.
  const [look] = useState(() => experimentArm(trayPanelLook));
  if (items.length === 0 && finished.length === 0) return null;
  // The header stays while the tray has more than one line, running or ended: one of two running
  // ending never takes it (and its collapse) away.
  const headed = items.length + finished.length > 1;
  const open = !headed || (opened ?? items.length <= TRAY_OPEN_MAX);
  // Its subagents and the chats it started are one word: subagents.
  const subagents = items.filter((item) => item.kind !== "command").length;
  const commands = items.length - subagents;
  // Running is what runs: a subagent or chat that waits on the person is counted as waiting.
  const waitingOnYou = items.filter((item) =>
    item.kind === "agent"
      ? subagentStatus(item.agent, waiting) === "waiting"
      : item.kind === "session" && item.session.state === "waiting",
  ).length;
  const running = subagents - waitingOnYou;
  const starts = items.map(itemStart).filter((start): start is number => start !== undefined);
  const title =
    [
      working ? running > 0 && t("subagents.allRunning", { n: running }) : items.length > 0 && t("bgWork.running"),
      !working && running > 0 && t("subagents.count", { n: running }),
      waitingOnYou > 0 && t("summary.subagents.waiting", { n: waitingOnYou }),
      commands > 0 && t("turn.working.commands", { n: commands }),
    ]
      .filter((part): part is string => typeof part === "string")
      .join(" · ") || t("summary.subagents");
  // Keep live and ended cards in one keyed child list. When a task completes, its card moves
  // between groups without remounting, so keyboard focus and the open affordance stay put.
  const cards = [
    ...items.map((item) => <li key={itemKey(item)}>{line(item)}</li>),
    ...finished.slice(0, showFinished ? finished.length : TRAY_OPEN_MAX).map((item, index) => (
      <li key={itemKey(item)} data-finished="" data-first-finished={index === 0 || undefined}>
        {line(item)}
      </li>
    )),
  ];
  // View all sits under the list, outside its scroller, so it never scrolls away either.
  const more = finished.length > TRAY_OPEN_MAX && (
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
  );
  return (
    <section
      className="acpmux-running-tray"
      aria-label={t("summary.subagents")}
      data-open={open || undefined}
      data-placement={placement}
      data-look={look}
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
      {open && more}
    </section>
  );

  function line(item: TrayItem) {
    if (item.kind === "agent")
      return (
        <AgentLine
          name={item.agent.name}
          detail={
            item.agent.state !== "running"
              ? item.agent.kind
              : item.agent.actionShell
                ? toolDetail(t, item.agent.action, true)
                : (item.agent.action ?? item.agent.kind)
          }
          mark={item.agent.harness}
          status={subagentStatus(item.agent, waiting)}
          state={subagentStateText(t, item.agent, waiting)}
          working={Boolean(retrying(item.agent))}
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
            name={sendLabel(t, item.command) ?? commandLabel(item.command)}
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
    // The chat's retry, as every surface reads it (retryState.ts ``sessionRetry``).
    const sessionPhase = sessionRetry(item.session);
    const sessionRetrying = sessionPhase.kind === "retrying" ? sessionPhase.retry : undefined;
    return (
      <AgentLine
        name={item.session.title}
        detail={liveSession(item.session) ? doingDetail(t, item.session.doing, item.session.doingTool) : undefined}
        title={item.session.doing}
        kind={t("tray.kind.subagent")}
        chevron
        icon="agent.chat"
        status={sessionRetrying ? "running" : SESSION_STATUS[item.session.state]}
        state={sessionRetrying ? retryLabel(t, sessionRetrying) : t(STATUS_LABEL[SESSION_STATUS[item.session.state]])}
        working={sessionRetrying !== undefined}
        onOpen={onOpenSession && (() => onOpenSession(item.session.sessionId))}
      />
    );
  }
});

const NO_ITEMS: readonly TrayItem[] = [];

/// What a line says it does now is only for what still runs: an ended one never reads "Running …".
const liveSession = (session: StartedSession) => session.state === "running" || session.state === "waiting";

/// A started chat's line: its turn runs, it waits on the person, its turn failed, or it is done.
const SESSION_STATUS: Record<StartedSession["state"], SubagentStatus> = {
  running: "running",
  waiting: "waiting",
  failed: "failed",
  idle: "done",
};
