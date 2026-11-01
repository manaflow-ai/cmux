// The tray of running work at the foot of the chat (runningTray.ts): a part of the bottom stack
// right above the composer (bottomStack.css), so it never scrolls away with history and the
// transcript keeps its last row above it. It is the one place running background work shows, in a
// turn and between turns. Each running subagent, background command (inspector/processes.ts
// `backgroundCommands`, the process registry's merged with the transcript's) and chat the agent
// started is one line (AgentLine.tsx, the summary card's rows too): its icon in the theme's accent,
// its name, what it does now, how long it has run (ticking) and its state, Running or Waiting. A
// click opens it: a subagent's pane or view (App.tsx `showSubagent`), a command's terminal
// (processTerminal.ts), a chat. A running subagent, and a command the registry lists, has a Stop
// square in the fixed row track and the same action in its context menu (a right-click, or Shift-F10
// and the menu key on the focused line). An agent another one spawned sits right under it.
//
// One item is its line alone. Several get a header first, as the Codex and Claude desktop apps
// head their running agents: a still running-work mark (never the spinner, which stays on each
// working line, #27103), "2 subagents running · 1 command", the time since the first started as
// quiet meta right after the counts (never a column of its own far from them), and the chevron in
// the trailing column every line's chevron ends in; between turns it says "Running in background ·
// 2 subagents · 1 command". The
// header counts exactly the lines under it: what runs or waits on the person. The chat's subagents
// and the chats its agent started are all "subagents" (Leo 2026-10-21: "SHOULDN'T THIS SAY
// SUBAGENTS?"). What ended stays as compact status cards after them, never counted. A command is
// named by what its call says it does (inspector/processes.ts `commandLabel`), a chat by its title
// and what its turn does now. A headed tray starts folded to its header, one line, so the tray never
// takes the transcript's room (https://github.com/manaflow-ai/cmux/issues/28875: two commands and a
// done subagent stood open over the chat), and the chevron opens it. The person's choice holds for
// that chat, across a switch away and back (trayFoldMemory.ts). Its
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
// a box in a box. Hovering a line that opens something fills that whole line to the tray's own
// edges (one inset), with the arrow, and the line stays lit while its menu is open; a line says its
// kind first ("Command", "Subagent") and ends in a chevron. A command's whole shell line is its
// tooltip; its menu's Stop stops only that command (`_acpmux/process/kill`), which the composer's
// Stop does not (that cancels the turn, and the command outlives it), so the item says so. (Leo 2026-10-21 on
// the strip: "why is that even highlighted in the first place? you can click on it to go
// somewhere? is that a command or a subagent?")
//
// It moves with the transcript (Leo 2026-10-26: "Like why is this not animating and, like,
// following along with the exact same things as everything else?"; trayMotion.tsx): it eases in as
// a new message does, leaves on a kept snapshot, its list opens and folds on the shared fold
// (conversation/fold.ts), a line that joins it rises in, and its header's words tick. What runs
// turns the shared spinner, never a breathing dot.
import { memo, type ReactElement, useCallback, useId, useLayoutEffect, useRef, useState } from "react";
import { experimentArm } from "../../../experiments/experiment";
import { ContextMenu, type ContextMenuItem } from "../../../ui/ContextMenu";
import { foldMotion, useFold } from "../conversation/fold";
import { entranceAllowed } from "../../shared/pageReveal";
import { formatDuration } from "../conversation/turns";
import { usePaneLanguage, useT, type Translate } from "../i18n";
import { Icon } from "../icons/Icon";
import { rowIconSize } from "../icons/iconSize";
import { arrivalKey, type BackgroundCommand, commandLabel, sendLabel } from "../session-info/processes";
import { StopButton as ProcessStopButton } from "../session-info/TasksSection";
import { STATUS_LABEL, type SubagentStatus, subagentStateText, subagentStatus } from "../summary/SubagentStatusList";
import { retrying, retryLabel, sessionRetry } from "./retryState";
import { AgentLine } from "./AgentLine";
import { agentTone } from "./agentTones";
import { subagentProgress } from "./subagentProgress";
import { BackgroundTaskTail } from "./BackgroundTaskTail";
import { elapsed, StopButton, useNow } from "./SubagentGroup";
import { itemStart, type TrayItem } from "./runningTray";
import { toolDetail } from "./trayDetail";
import { trayPanelLook, trayRowLook } from "./trayPanel.experiment";
import { trayMotionLook } from "./trayMotion.experiment";
import { trayHeadLook } from "./trayHead.experiment";
import { Tick, useTrayMotion } from "./trayMotion";
import type { StartedSession } from "../started/startedSessions";
import type { Subagent } from "./subagentFold";
import type { SubagentTrayPlacement } from "./subagentTrayPlacement";
import { rememberTrayOpen, trayOpenFor } from "./trayFoldMemory";

/// Ended lines the tray shows before View all.
export const TRAY_OPEN_MAX = 3;

const ROW_ICON = rowIconSize(12);

const itemKey = (item: TrayItem): string =>
  item.kind === "command" ? `command:${arrivalKey(item.command)}` : `${item.kind}:${item.id}`;

/// What a line's Stop is keyed by while it can stop: a running subagent the harness stops, or a
/// command acpmux lists; else nothing.
const stopKey = (item: TrayItem): string | undefined =>
  item.kind === "agent"
    ? item.agent.state === "running" && !item.agent.command
      ? `agent:${item.agent.id}`
      : undefined
    : item.kind === "command" && item.command.processId
      ? `process:${item.command.processId}`
      : undefined;

/// A line's menu with nothing to stop.
const NO_STOP: readonly ContextMenuItem[] = [];

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
  chat,
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
  /// The chat the tray belongs to: the person's open or fold holds for it (trayFoldMemory.ts).
  chat?: string;
}) {
  const t = useT();
  const language = usePaneLanguage();
  const listId = useId();
  const now = useNow(items.length > 0);
  const trayNode = useRef<HTMLElement | null>(null);
  const [narrow, setNarrow] = useState(false);
  // Folded until the person opens it; their choice holds for this chat (trayFoldMemory.ts).
  const [opened, setOpened] = useState<boolean | undefined>(() => trayOpenFor(chat));
  const [showFinished, setShowFinished] = useState(false);
  const [openCommands, setOpenCommands] = useState<ReadonlySet<string>>(() => new Set());
  // Each line's Stop, as its menu item: off while the request is out (and after it is taken, until
  // that run ends); when acpmux or the harness refuses, the item says so and can be tried again.
  const [stops, setStops] = useState<ReadonlyMap<string, "stopping" | "failed">>(() => new Map());
  // Read once per tray: the arm is the gallery's override or a dogfood key, never a per-tick read.
  const [look] = useState(() => experimentArm(trayPanelLook));
  const [motion] = useState(() => experimentArm(trayMotionLook));
  const [row] = useState(() => experimentArm(trayRowLook));
  const [head] = useState(() => experimentArm(trayHeadLook));
  // Only the bottom stack's tray leaves on a snapshot: one placed in the transcript moves with it.
  const motionRef = useTrayMotion(shown, enters, placement === "tray");
  const setTrayRef = useCallback(
    (node: HTMLElement | null) => {
      trayNode.current = node;
      return motionRef(node);
    },
    [motionRef],
  );
  useLayoutEffect(() => {
    const node = trayNode.current;
    if (!node || typeof ResizeObserver === "undefined") return;
    const update = (width: number) =>
      setNarrow((current) => {
        const next = width <= 400;
        return current === next ? current : next;
      });
    update(node.getBoundingClientRect().width);
    const observer = new ResizeObserver(([entry]) =>
      update(entry?.contentRect.width ?? node.getBoundingClientRect().width),
    );
    observer.observe(node);
    return () => observer.disconnect();
  }, []);
  // The header stays while the tray has more than one line, running or ended: one of two running
  // ending never takes it (and its collapse) away.
  const headed = items.length + finished.length > 1;
  const open = !headed || opened === true;
  // The list opens and folds on the shared fold, its height only (no fade in), from the header's
  // chevron, or a lone line gaining a header (the tray then folds to it).
  // A fold while the page is away (hidden, or in its first frames back) applies at once: the shared
  // page-reveal gate (shared/pageReveal.ts), read only when the fold changes.
  const fold = useFold(open, entranceMayRun, false);
  // A fold the person did not ask for (a lone line gaining a header) makes the list inert under a
  // focused line or Stop: focus moves to the header that folded it, never to the page's body. With no
  // motion the fold leaves in the same commit and takes the focused line with it, so whether focus
  // was in the list is kept as it moves (onFocus/onBlur below), not read after the commit.
  const headButton = useRef<HTMLButtonElement | null>(null);
  const focusInList = useRef(false);
  useLayoutEffect(() => {
    if (open || !focusInList.current) return;
    focusInList.current = false;
    const tray = trayNode.current;
    const focused = tray?.ownerDocument.activeElement;
    // Fell to the page (the line left with the fold), or still in the tray (an inert line): only
    // then. Focus the person put elsewhere since stays where it is.
    const fell = !focused || focused === tray?.ownerDocument.body;
    if ((fell || tray?.contains(focused)) && focused !== headButton.current) headButton.current?.focus();
  }, [open]);
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
    // A Stop's state lasts one run: a line that ends (or leaves) drops it, so a run that resumes
    // under the same id can be stopped again (#28533's review).
    if (stops.size > 0) {
      const stoppable = new Set(items.map(stopKey).filter((key): key is string => key !== undefined));
      if ([...stops.keys()].some((key) => !stoppable.has(key)))
        setStops((current) => new Map([...current].filter(([key]) => stoppable.has(key))));
    }
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
  // A fully folded tray has only its header. Avoid building hundreds of hidden row
  // elements on each header clock tick; keep them while a close animation still plays.
  const cards = fold.present
    ? [
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
      ]
    : [];
  // The header's mark is in the accent while anything under it runs.
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
      <Icon name={showFinished ? "disclosure.expanded" : "disclosure.collapsed"} size={ROW_ICON} row />
    </button>
  );
  return (
    <section
      ref={setTrayRef}
      className="acpmux-running-tray"
      aria-label={t("summary.subagents")}
      data-open={open || undefined}
      data-placement={placement}
      data-look={look}
      data-row={row}
      // Nothing runs: the ended lines sit quietly over the composer, no card around them (Leo,
      // 2026-10-31, on a finished one-line row in a bordered card: "why is this still so ass").
      data-settled={items.length === 0 || undefined}
      data-motion={motion}
      data-narrow={narrow || undefined}
      data-head={head}
    >
      {headed && (
        <button
          type="button"
          ref={headButton}
          className="acpmux-summary-row acpmux-summary-link acpmux-running-tray__head"
          aria-expanded={open}
          aria-controls={open ? listId : undefined}
          onClick={() => {
            setOpened(!open);
            rememberTrayOpen(chat, !open);
          }}
        >
          {head !== "bare" && (
            <span className="acpmux-lineage__icon" data-state={runs ? "running" : "done"}>
              <Icon name={head === "session" ? "agent.session" : HEAD_ICON} size={ROW_ICON} row />
            </span>
          )}
          <Tick className="acpmux-summary-text acpmux-running-tray__title" text={title} />
          {/* Quiet meta right after the counts, never a column of its own far from them. */}
          <span className="acpmux-summary-meta acpmux-running-tray__time" aria-hidden={starts.length === 0}>
            {starts.length > 0 ? formatDuration(Math.max(0, now - Math.min(...starts))) : undefined}
          </span>
          {/* The one trailing column every line's chevron and View all's end in. */}
          <span className="acpmux-running-tray__status">
            <Icon name={open ? "disclosure.expanded" : "disclosure.collapsed"} size={ROW_ICON} row />
          </span>
        </button>
      )}
      {fold.present && (
        // While it folds away its lines are out of reach: no focus, no reading.
        <div
          ref={fold.ref}
          className="acpmux-running-tray__fold"
          inert={!open || undefined}
          aria-hidden={!open || undefined}
          onFocus={() => {
            focusInList.current = true;
          }}
          onBlur={(event) => {
            // Only focus that moves to another control leaves the list. A blur to nothing (the
            // focused line removed or made inert by the fold, the window losing focus) keeps it,
            // for the effect above to read against where focus is then.
            const to = event.relatedTarget as Node | null;
            if (to && !event.currentTarget.contains(to)) focusInList.current = false;
          }}
        >
          <ul id={listId} className="acpmux-running-tray__list">
            {cards}
          </ul>
          {more}
        </div>
      )}
    </section>
  );

  /// A line in its context menu's host. The host stays when there is nothing to stop (no items, so a
  /// right-click keeps the default and no menu opens): a line that ends, or whose command's process
  /// id arrives, is the same node, and keeps its focus (#28533's review).
  function menu(node: ReactElement, item: ContextMenuItem | false | undefined | "" | null) {
    return (
      <ContextMenu className="acpmux-running-tray__menu" items={item ? [item] : NO_STOP}>
        {node}
      </ContextMenu>
    );
  }

  /// The menu's Stop for one line, keyed by what it stops.
  function stopItem(key: string, name: string, label: string, run: () => Promise<unknown>): ContextMenuItem {
    const state = stops.get(key);
    const mark = (next: "stopping" | "failed") =>
      setStops((current) => {
        const updated = new Map(current);
        updated.set(key, next);
        return updated;
      });
    return {
      id: "stop",
      label: state === "failed" ? t("subagents.stopFailed", { name }) : label,
      symbol: "stop.circle",
      disabled: state === "stopping",
      destructive: true,
      onSelect: () => {
        mark("stopping");
        run().catch(() => mark("failed"));
      },
    };
  }

  function line(item: TrayItem) {
    if (item.kind === "agent")
      return menu(
        <AgentLine
          name={item.agent.name}
          progress={subagentProgress(t, language, item.agent, { usage: false }).join(" · ") || undefined}
          progressAgent={item.agent}
          mark={item.agent.harness}
          tone={agentTone(item.agent.id)}
          status={subagentStatus(item.agent, waiting)}
          working={subagentStatus(item.agent, waiting) === "running"}
          state={subagentStateText(t, item.agent, waiting)}
          quiet={quietAgent(item.agent, waiting)}
          time={formatDuration(elapsed(item.agent, now))}
          depth={item.depth}
          // Its kind and what it does now are off the line (Leo, 2026-10-31: "a lot of these
          // subtitles are bad"); the tooltip keeps them under its task.
          title={agentTooltip(t, item.agent)}
          label={t("subagents.open", { name: item.agent.name })}
          chevron
          trayColumns
          // A narrow tray's second line is its time and controls: the stats wrap under the title.
          progressAt={row === "below" || narrow ? "below" : "meta"}
          onOpen={() => onOpen(item.agent.id)}
          after={
            stop &&
            item.agent.state === "running" &&
            !item.agent.command && <StopButton agent={item.agent} stop={stop} />
          }
        />,
        // An agent a shell call started stops with that call, not through the harness.
        stop &&
          item.agent.state === "running" &&
          !item.agent.command &&
          stopItem(stopKey(item)!, item.agent.name, t("subagents.stop", { name: item.agent.name }), () =>
            stop(item.agent.id),
          ),
      );
    if (item.kind === "command") {
      const key = itemKey(item);
      const processId = item.command.processId;
      return (
        <>
          {menu(
            <AgentLine
              name={sendLabel(t, item.command) ?? commandLabel(item.command)}
              title={item.command.command}
              kind={t("tray.kind.command")}
              chevron
              icon="terminal"
              working
              status="running"
              state={t("subagents.state.running")}
              quiet
              expanded={canOpenTerminal ? openCommands.has(key) : undefined}
              trayColumns
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
                processId && (
                  <ProcessStopButton
                    id={processId}
                    name={item.command.command}
                    label={t("tray.stopCommand")}
                    stop={stopProcess}
                  />
                )
              }
            />,
            stopProcess &&
              processId &&
              stopItem(stopKey(item)!, item.command.command, t("tray.stopCommand"), () => stopProcess(processId)),
          )}
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
        title={item.session.doing}
        mark={item.session.harness}
        tone={agentTone(item.session.sessionId)}
        chevron
        icon="agent.chat"
        status={sessionRetrying ? "running" : SESSION_STATUS[item.session.state]}
        working={sessionRetrying !== undefined || item.session.state === "running"}
        state={sessionRetrying ? retryLabel(t, sessionRetrying) : t(STATUS_LABEL[SESSION_STATUS[item.session.state]])}
        quiet={!sessionRetrying && (item.session.state === "running" || item.session.state === "idle")}
        trayColumns
        onOpen={onOpenSession && (() => onOpenSession(item.session.sessionId))}
      />
    );
  }
});

/// A subagent's state needs no word on its line when its glyph says it: done, or running under the
/// spinner. Waiting, failed, stopped and a retry keep theirs.
const quietAgent = (agent: Subagent, waiting: ReadonlySet<string>) => {
  if (retrying(agent)) return false;
  const status = subagentStatus(agent, waiting);
  return status === "done" || status === "running";
};

/// What the line no longer says, in its tooltip: its task, its kind (Explore, general-purpose) and,
/// while it runs, what it does now.
function agentTooltip(t: Translate, agent: Subagent): string | undefined {
  const doing =
    agent.state !== "running" ? undefined : agent.actionShell ? toolDetail(t, agent.action, true) : agent.action;
  const lines = [agent.task, agent.kind && agent.kind !== agent.name ? agent.kind : undefined, doing];
  return lines.filter((line): line is string => Boolean(line)).join("\n") || undefined;
}

/// The header's fixed mark for background work (trayHead.experiment.ts): a running ring, never the
/// chat bubble, which reads as a message, and never the spinner, which each working line keeps.
const HEAD_ICON = "app.sample.runningagents";
const NO_ITEMS: readonly TrayItem[] = [];
const NO_ARRIVALS: ReadonlySet<string> = new Set();
/// The most lines that rise in from one update; a bigger burst is simply there.
const ARRIVALS_PER_UPDATE = 3;
/// The shared gate on an entrance or a fold now: the page shows, its first frame back has passed, and
/// the host's motion is on (shared/pageReveal.ts).
const entranceMayRun = () => entranceAllowed();

/// A started chat's line: its turn runs, it waits on the person, its turn failed, or it is done.
const SESSION_STATUS: Record<StartedSession["state"], SubagentStatus> = {
  running: "running",
  waiting: "waiting",
  failed: "failed",
  idle: "done",
};
