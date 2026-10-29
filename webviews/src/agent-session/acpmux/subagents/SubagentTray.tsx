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
//
// It moves with the transcript (Leo 2026-10-26: "Like why is this not animating and, like,
// following along with the exact same things as everything else?"; trayMotion.tsx): it eases in as
// a new message does, leaves on a kept snapshot, its list opens and folds on the shared fold
// (conversation/fold.ts), a line that joins it rises in, and its header's words tick. What runs
// turns the shared spinner, never a breathing dot.
import { memo, useId, useRef, useState } from "react";
import { experimentArm } from "../../../experiments/experiment";
import { foldMotion, useFold } from "../conversation/fold";
import { entranceAllowed } from "../../shared/pageReveal";
import { Spinner } from "../conversation/icons";
import { formatDuration } from "../conversation/turns";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { arrivalKey, type BackgroundCommand, commandLabel, sendLabel } from "../inspector/processes";
import { StopButton as ProcessStopButton } from "../inspector/TasksSection";
import { STATUS_LABEL, type SubagentStatus, subagentStatus, subagentStatusLabel } from "../summary/SubagentStatusList";
import { AgentLine } from "./AgentLine";
import { BackgroundTaskTail } from "./BackgroundTaskTail";
import { elapsed, StopButton, useNow } from "./SubagentGroup";
import { itemStart, type TrayItem } from "./runningTray";
import { doingDetail, toolDetail } from "./trayDetail";
import { trayPanelLook } from "./trayPanel.experiment";
import { trayMotionLook } from "./trayMotion.experiment";
import { Tick, useTrayMotion } from "./trayMotion";
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
  shown,
  enters = false,
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
  /// The chat on screen, as of the latest render (App.tsx): the tray plays its exit only when it
  /// goes while its chat still shows (trayMotion.tsx `useTrayMotion`); none, no entrance or exit.
  shown?: { readonly current: string | undefined };
  /// The tray appears in a chat that showed without it: it eases in.
  enters?: boolean;
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
  const [motion] = useState(() => experimentArm(trayMotionLook));
  // Only the bottom stack's tray leaves on a snapshot: one placed in the transcript moves with it.
  const motionRef = useTrayMotion(shown, enters, placement === "tray");
  // The header stays while the tray has more than one line, running or ended: one of two running
  // ending never takes it (and its collapse) away.
  const headed = items.length + finished.length > 1;
  const open = !headed || (opened ?? items.length <= TRAY_OPEN_MAX);
  // The list opens and folds on the shared fold, its height only (no fade in), from the header's
  // chevron or the list growing past TRAY_OPEN_MAX.
  // A fold while the page is away (hidden, or in its first frames back) applies at once: the shared
  // page-reveal gate (shared/pageReveal.ts), read only when the fold changes.
  const fold = useFold(open, entranceMayRun, false);
  // A line that joins the open list rises in (ui/popupSurface.css `data-enter`); the lines it was
  // drawn with, and lines a fold or View all brings back, are simply there. With no motion (Reduce
  // Motion, the host's switch, a page away: hidden, or in its first frames back, shared/pageReveal.ts)
  // nothing arrives. A burst (more than ARRIVALS_PER_UPDATE new lines at once, a reconnect's
  // catch-up) is simply there too, as the transcript's live rows are, so the arrived set stays a
  // handful. The lines are compared only when the tray's lists change (an event), never on the
  // clock's tick, so a long ended history costs nothing per second.
  const seen = useRef<ReadonlySet<string> | null>(null);
  const comparedFor = useRef<{ items: readonly TrayItem[]; finished: readonly TrayItem[] } | null>(null);
  const [arrived, setArrived] = useState<ReadonlySet<string>>(NO_ARRIVALS);
  if (comparedFor.current?.items !== items || comparedFor.current.finished !== finished) {
    comparedFor.current = { items, finished };
    const keys = new Set([...items.map(itemKey), ...finished.map(itemKey)]);
    const known = seen.current ?? keys;
    seen.current = keys;
    const fresh = [...keys].filter((key) => !known.has(key));
    if (
      fresh.length > 0 &&
      fresh.length <= ARRIVALS_PER_UPDATE &&
      open &&
      !foldMotion.reducedMotion() &&
      entranceMayRun()
    ) {
      const drawn = new Set([
        ...items.map(itemKey),
        ...finished.slice(0, showFinished ? finished.length : TRAY_OPEN_MAX).map(itemKey),
      ]);
      const rising = fresh.filter((key) => drawn.has(key));
      if (rising.length > 0) setArrived((current) => new Set([...current, ...rising]));
    }
  }
  /// A line's entrance is played (ended, cancelled or unmounted first): it never replays.
  const played = (key: string) =>
    setArrived((current) => {
      if (!current.has(key)) return current;
      const next = new Set(current);
      next.delete(key);
      return next;
    });
  const arrivals = { arrived, played };
  const arrivalRefs = useRef(new Map<string, (node: HTMLElement | null) => (() => void) | undefined>());
  if (items.length === 0 && finished.length === 0) return null;
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
  // Ended, cancelled (motion turned off midway) or unmounted first (a fold, View all), a line's
  // entrance is played: it never replays. React has no animationcancel prop, so both listen on the
  // line's node through a ref kept per key (a new ref each render would detach mid-entrance).
  const arriving = (key: string) => {
    if (!arrivals.arrived.has(key)) return undefined;
    let ref = arrivalRefs.current.get(key);
    if (!ref) {
      ref = (node: HTMLElement | null) => {
        if (!node) return undefined;
        const ended = (event: Event) => {
          if (event.target === node) arrivals.played(key);
        };
        node.addEventListener("animationend", ended);
        node.addEventListener("animationcancel", ended);
        return () => {
          node.removeEventListener("animationend", ended);
          node.removeEventListener("animationcancel", ended);
          arrivalRefs.current.delete(key);
          arrivals.played(key);
        };
      };
      arrivalRefs.current.set(key, ref);
    }
    return { "data-enter": "bottom" as const, ref };
  };
  const cards = [
    ...items.map((item) => (
      <li key={itemKey(item)} {...arriving(itemKey(item))}>
        {line(item)}
      </li>
    )),
    ...finished.slice(0, showFinished ? finished.length : TRAY_OPEN_MAX).map((item, index) => (
      <li
        key={itemKey(item)}
        data-finished=""
        data-first-finished={index === 0 || undefined}
        {...arriving(itemKey(item))}
      >
        {line(item)}
      </li>
    )),
  ];
  // The header's spinner is a running line's: it turns while anything under it runs.
  const runs = running > 0 || commands > 0;
  // View all sits under the list, outside its scroller, so it never scrolls away either.
  const more = finished.length > TRAY_OPEN_MAX && (
    <button
      type="button"
      className="acpmux-summary-row acpmux-summary-link acpmux-running-tray__finished"
      aria-expanded={showFinished}
      onClick={() => setShowFinished(!showFinished)}
    >
      <Tick
        className="acpmux-summary-text"
        text={showFinished ? t("summary.showFewer") : t("summary.viewAll", { n: finished.length })}
      />
      <Icon name={showFinished ? "disclosure.expanded" : "disclosure.collapsed"} size={12} />
    </button>
  );
  return (
    <section
      ref={motionRef}
      className="acpmux-running-tray"
      aria-label={t("summary.subagents")}
      data-open={open || undefined}
      data-placement={placement}
      data-look={look}
      data-motion={motion}
    >
      {headed && (
        <button
          type="button"
          className="acpmux-summary-row acpmux-summary-link acpmux-running-tray__head"
          aria-expanded={open}
          aria-controls={open ? listId : undefined}
          onClick={() => setOpened(!open)}
        >
          <span className="acpmux-lineage__icon" data-state={runs ? "running" : "done"}>
            {runs ? <Spinner size={14} loading /> : <Icon name="agent.session" size={14} />}
          </span>
          <Tick className="acpmux-summary-text acpmux-running-tray__title" text={title} />
          {starts.length > 0 && (
            <span className="acpmux-summary-meta acpmux-running-tray__time">
              {formatDuration(Math.max(0, now - Math.min(...starts)))}
            </span>
          )}
          <Icon name={open ? "disclosure.expanded" : "disclosure.collapsed"} size={12} />
        </button>
      )}
      {fold.present && (
        // While it folds away its lines are out of reach: no focus, no reading.
        <div
          ref={fold.ref}
          className="acpmux-running-tray__fold"
          inert={!open || undefined}
          aria-hidden={!open || undefined}
        >
          <ul id={listId} className="acpmux-running-tray__list">
            {cards}
          </ul>
          {more}
        </div>
      )}
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
          working={subagentStatus(item.agent, waiting) === "running"}
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
    return (
      <AgentLine
        name={item.session.title}
        detail={liveSession(item.session) ? doingDetail(t, item.session.doing, item.session.doingTool) : undefined}
        title={item.session.doing}
        kind={t("tray.kind.subagent")}
        chevron
        icon="agent.chat"
        status={SESSION_STATUS[item.session.state]}
        working={item.session.state === "running"}
        state={t(STATUS_LABEL[SESSION_STATUS[item.session.state]])}
        onOpen={onOpenSession && (() => onOpenSession(item.session.sessionId))}
      />
    );
  }
});

const NO_ITEMS: readonly TrayItem[] = [];
const NO_ARRIVALS: ReadonlySet<string> = new Set();
/// The most lines that rise in from one update; a bigger burst is simply there.
const ARRIVALS_PER_UPDATE = 3;
/// The shared gate on an entrance or a fold now: the page shows, its first frame back has passed, and
/// the host's motion is on (shared/pageReveal.ts).
const entranceMayRun = () => entranceAllowed();

/// What a line says it does now is only for what still runs: an ended one never reads "Running …".
const liveSession = (session: StartedSession) => session.state === "running" || session.state === "waiting";

/// A started chat's line: its turn runs, it waits on the person, its turn failed, or it is done.
const SESSION_STATUS: Record<StartedSession["state"], SubagentStatus> = {
  running: "running",
  waiting: "waiting",
  failed: "failed",
  idle: "done",
};
