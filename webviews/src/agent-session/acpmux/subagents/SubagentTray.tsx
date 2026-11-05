// The tray of running work at the foot of the chat (runningTray.ts): a part of the bottom stack
// right above the composer (bottomStack.css), so it never scrolls away with history and the
// transcript keeps its last row above it. It is the one place running background work shows, in a
// turn and between turns. Each running subagent, background command (inspector/processes.ts
// `backgroundCommands`, the process registry's merged with the transcript's) and chat the agent
// started is one line (AgentLine.tsx, the summary card's rows too): its icon in the theme's accent,
// its name, what it does now, how long it has run (ticking) and its state when it waits (a running
// line says it runs by its time and Stop alone, no spinner and no "Running" word; Leo, 2026-11-03). A
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
// header counts what runs or waits on the person kind by kind, then what ended in the list ("1
// subagent done", its failures in red) and the mark of a subagent of another model family
// (trayHeadKinds.ts; Leo, 2026-11-03: "the top should be able to split per background task/scheduled
// wait/subagent/subsession?"). A session the agent started reads as a session. A command is
// named by what its call says it does, else in words (session-info/commandRules.ts `commandRead`), a chat by its title
// and what its turn does now. A headed tray starts folded to its header, one line, so the tray never
// takes the transcript's room (https://github.com/manaflow-ai/cmux/issues/28875: two commands and a
// done subagent stood open over the chat), and the chevron opens it. The person's choice holds for
// that chat, across a switch away and back (trayFoldMemory.ts). The header expands in place, and
// its panel button (in the lines' Stop column, right before the chevron) opens the full Background
// tasks panel, as Claude's "N background commands completed, M running ›" chip opens its panel
// (Leo, 2026-11-03: "a thing like this that can either expand OR open up to this sort of thing";
// trayOpen.experiment.ts). Its
// glass is the user bubble's: the theme's text at a low strength over the backdrop, with the
// composer's hairline rim.
//
// The header is pinned (Leo 2026-10-25: "the sort of collapse at the top section, like that
// disappears for some reason at the top ... sometimes it disappears"). It went for two reasons: the
// bottom stack made the whole tray its own scroller (bottomStack.css `overflow-y: auto` on every
// part), so in a short pane, or with the list's ended cards, the header scrolled up and out with the
// lines; and it only drew with two running lines, so once one of two ended it unmounted while its
// ended cards stayed. Now the tray is a column that never scrolls: the header on top, then the list
// (running first, then the ones that ended last), the only part that scrolls. Every line is in
// it: no View all under it, the list scrolls past its five lines (Leo, 2026-11-01: "why is there even
// a view all 5 button it's useless just let it be scroll-downable"). The header shows whenever the
// tray has more than one line, running or ended.
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
import {
  type CSSProperties,
  memo,
  type ReactElement,
  useCallback,
  useContext,
  useId,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import { experimentArm } from "../../../experiments/experiment";
import { ContextMenu, type ContextMenuItem } from "../../../ui/ContextMenu";
import { foldMotion, useFold } from "../conversation/fold";
import { entranceAllowed } from "../../shared/pageReveal";
import { formatDuration } from "../conversation/turns";
import { usePaneLanguage, useT, type Translate } from "../i18n";
import { Icon } from "../icons/Icon";
import { rowIconSize } from "../icons/iconSize";
import { arrivalKey, type BackgroundCommand, sendLabel } from "../session-info/processes";
import { commandRead } from "../session-info/commandRules";
import { currentCommandRules } from "../session-info/commandLabelSettings";
import { StopButton as ProcessStopButton } from "../session-info/TasksSection";
import { STATUS_LABEL, type SubagentStatus, subagentStateText, subagentStatus } from "../summary/SubagentStatusList";
import { retrying, retryLabel, sessionRetry } from "./retryState";
import { AgentMark } from "../../shared/AgentMark";
import { AgentLine } from "./AgentLine";
import { AgentIdentity, foreignHarness, SUBAGENT_FALLBACK } from "./AgentIdentity";
import { harnessFamily } from "./agentRuns";
import { agentTone } from "./agentTones";
import { subagentProgress } from "./subagentProgress";
import { subagentDisplayName, subagentTaskLabel } from "./subsessions";
import { BackgroundTaskTail } from "./BackgroundTaskTail";
import { elapsed, StopButton, SubagentHarnessContext, useNow } from "./SubagentGroup";
import { itemStart, type TrayItem } from "./runningTray";
import { attentionFirst } from "./trayAttention";
import { latestLine, toolDetail } from "./trayDetail";
import { trayLatestLook } from "./trayLatest.experiment";
import { trayPanelLook, trayRowLook, trayStopLook } from "./trayPanel.experiment";
import { trayMotionLook } from "./trayMotion.experiment";
import { trayHeadLook } from "./trayHead.experiment";
import { trayFoldHeadLook } from "./trayFoldHead.experiment";
import { trayOpenLook } from "./trayOpen.experiment";
import { trayHeadKindsLook } from "./trayHeadKinds.experiment";
import { trayHead } from "./trayHeadKinds";
import { COMMAND_KIND_ICON, commandKind } from "./trayCommandKinds";
import { KIND_LINE_SEPARATOR, trayKindLineLook } from "./trayKindLine.experiment";
import { traySurfaceLook } from "./traySurface.experiment";
import { Tick, useTrayMotion } from "./trayMotion";
import type { StartedSession } from "../started/startedSessions";
import { awaitsOwnWork, type Subagent } from "./subagentFold";
import type { SubagentTrayPlacement } from "./subagentTrayPlacement";
import { rememberTrayOpen, trayOpenFor } from "./trayFoldMemory";
import { PlanList } from "../conversation/PlanList";
import type { AcpmuxPlanEntry } from "../model";
import type { TrayHandleSide } from "../chatDisplay";

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
  onOpenPanel,
  stop,
  stopProcess,
  placement = "tray",
  shown,
  enters = false,
  chat,
  plan,
  planEarlier = false,
  onTuck,
  tuckSide = "middle",
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
  /// Opens the chat's Background tasks panel (App.tsx `openBackgroundPanel`): the header expands in
  /// place, and its panel button opens the full view (trayOpen.experiment.ts). Unset (Quick Chat, which
  /// has no right column for it), the header only expands.
  onOpenPanel?: () => void;
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
  /// The running turn's todo list (an ACP `plan`), shown in the header as "2 of 5 · <current task>"
  /// and, opened, as its checklist over the lines (Leo, 2026-11-03: "did we like/prefer that tho to
  /// the little composer hat we have rn"). Unset between turns: the ended list folds in the transcript.
  plan?: readonly AcpmuxPlanEntry[];
  /// `plan` is an earlier turn's list with steps left, carried while the running turn has none of its
  /// own (turns.ts `earlierTurnPlan`): the header reads "Earlier plan · 2 of 5", the list says why.
  planEarlier?: boolean;
  /// Tucks the hat away to a pull tab on the composer's top edge (TrayPullTab.tsx): a chevron
  /// on the hat's own top edge, shown on hover (Leo, 2026-11-04: "at the top of the hat, there's
  /// some sort of little thing ... a special kind of chevron"). Unset, the hat can't tuck away.
  onTuck?: () => void;
  /// Where the tuck chevron sits along the hat's top edge, as the pull tab does along the composer's
  /// (chatDisplay.ts TRAY_HANDLE_KEY).
  tuckSide?: TrayHandleSide;
}) {
  const t = useT();
  const language = usePaneLanguage();
  // The chat's harness, for a subagent that names none (SubagentGroup.tsx `Avatar`).
  const chatHarness = useContext(SubagentHarnessContext);
  const listId = useId();
  const now = useNow(items.length > 0);
  const trayNode = useRef<HTMLElement | null>(null);
  const [narrow, setNarrow] = useState(false);
  // Room for one name in the folded header, not two: a measured narrow tray (an unmeasured one, 0px,
  // keeps two).
  const [oneName, setOneName] = useState(false);
  // Folded until the person opens it; their choice holds for this chat (trayFoldMemory.ts).
  const [opened, setOpened] = useState<boolean | undefined>(() => trayOpenFor(chat));
  const [openCommands, setOpenCommands] = useState<ReadonlySet<string>>(() => new Set());
  // Each line's Stop, as its menu item: off while the request is out (and after it is taken, until
  // that run ends); when acpmux or the harness refuses, the item says so and can be tried again.
  const [stops, setStops] = useState<ReadonlyMap<string, "stopping" | "failed">>(() => new Map());
  // Read once per tray: the arm is the gallery's override or a dogfood key, never a per-tick read.
  const [look] = useState(() => experimentArm(trayPanelLook));
  const [motion] = useState(() => experimentArm(trayMotionLook));
  const [row] = useState(() => experimentArm(trayRowLook));
  const [head] = useState(() => experimentArm(trayHeadLook));
  const [surface] = useState(() => experimentArm(traySurfaceLook));
  const [foldHead] = useState(() => experimentArm(trayFoldHeadLook));
  const [stopLook] = useState(() => experimentArm(trayStopLook));
  const [latestAt] = useState(() => experimentArm(trayLatestLook));
  const [opensArm] = useState(() => experimentArm(trayOpenLook));
  const [kindsArm] = useState(() => experimentArm(trayHeadKindsLook));
  const [kindLine] = useState(() => experimentArm(trayKindLineLook));
  // How the header reaches the Background tasks panel, where the chat has one (Leo, 2026-11-03: "a
  // thing like this that can either expand OR open up to this sort of thing"): a panel button beside
  // its chevron (the default), or the whole header, Claude's chip.
  // A header that opens the panel can't open the plan, which lives only here: with a plan it falls
  // back to the panel button, so the checklist and the panel both stay a click away.
  const panelArm = opensArm === "header" && plan !== undefined && plan.length > 0 ? "button" : opensArm;
  const opensPanel = onOpenPanel && panelArm !== "none" ? panelArm : undefined;
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
    const update = (width: number) => {
      setNarrow((current) => {
        const next = width <= 400;
        return current === next ? current : next;
      });
      setOneName((current) => {
        const next = width > 0 && width <= 400;
        return current === next ? current : next;
      });
    };
    update(node.getBoundingClientRect().width);
    const observer = new ResizeObserver(([entry]) =>
      update(entry?.contentRect.width ?? node.getBoundingClientRect().width),
    );
    observer.observe(node);
    return () => observer.disconnect();
  }, []);
  // The header stays while the tray has more than one line, running or ended: one of two running
  // ending never takes it (and its collapse) away.
  const planned = plan !== undefined && plan.length > 0;
  const headed = items.length + finished.length > 1 || planned;
  // A header that opens the panel never expands in place.
  const open = !headed || (opened === true && opensPanel !== "header");
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
  // drawn with, and lines a fold brings back, are simply there. With no motion (Reduce
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
      const drawn = new Set([...items.map(itemKey), ...finished.map(itemKey)]);
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
  // What runs by name, newest first: computed when the items change (an event), never per tick.
  // The width the list's scrollbar takes, if it takes any (a classic, always-shown scrollbar): the
  // header's panel button and chevron move in by it too, so they stay over the lines' Stop and chevron
  // columns (Leo, 2026-11-03: "all that alignment can be done better ... the chevrons with the stop
  // symbols"). One observer on the list while it is mounted; it disconnects with the list.
  const [gutter, setGutter] = useState(0);
  const listRef = useCallback((node: HTMLUListElement | null) => {
    if (!node) return undefined;
    const update = () => {
      const next = Math.max(0, node.offsetWidth - node.clientWidth);
      setGutter((current) => (current === next ? current : next));
    };
    update();
    if (typeof ResizeObserver === "undefined") return undefined;
    const observer = new ResizeObserver(update);
    observer.observe(node);
    return () => {
      observer.disconnect();
      setGutter(0);
    };
  }, []);
  const newest = useMemo(() => newestNames(t, items), [t, items]);
  const ordered = useMemo(() => attentionFirst(items, finished, waiting), [items, finished, waiting]);
  const headMarks = useMemo(
    () => (head === "stack" ? stackMarks(t, items, finished, chatHarness) : NO_MARKS),
    [t, head, items, finished, chatHarness],
  );
  const headCounts = useMemo(
    () =>
      trayHead(t, {
        items,
        finished,
        waiting,
        working,
        chatHarness,
        arm: kindsArm,
        separator: KIND_LINE_SEPARATOR[kindLine],
      }),
    [t, items, finished, waiting, working, chatHarness, kindsArm, kindLine],
  );
  if (items.length === 0 && finished.length === 0 && !planned) return null;
  // The counts, split by kind, then what ended and failed (trayHeadKinds.ts; Leo, 2026-11-03: "the
  // top bit aka what the collapsed area shows i think can show much more interesting stuf fthan it
  // does now").
  const counts = headCounts;
  // A measured narrow tray keeps room for its counts: one mark, in the lines' icon column (an
  // unmeasured one, 0px, keeps them all, as `oneName` keeps two names). A family the drawn marks
  // already show is not drawn again after the counts; one they leave out still is.
  const drawnMarks = headMarks.slice(0, oneName ? 1 : STACK_MARKS);
  const stacked = new Set(drawnMarks.flatMap((mark) => (mark.harness ? [harnessFamily(mark.harness)] : [])));
  const trailingMarks = counts.marks.filter((harness) => !stacked.has(harnessFamily(harness)));
  const title = counts.text;
  // Its subagents and the chats it started run, or a command does: the header's mark is lit.
  const commands = items.filter((item) => item.kind === "command").length;
  const running = items.filter((item) =>
    item.kind === "agent"
      ? subagentStatus(item.agent, waiting) !== "waiting"
      : item.kind === "session" && item.session.state !== "waiting",
  ).length;
  const starts = items.map(itemStart).filter((start): start is number => start !== undefined);
  // Folded, the header is the one line above the composer, so it names what runs, newest first, as
  // Claude Code's running-tasks list does (trayFoldHead.experiment.ts; Leo, 2026-11-03: "the
  // "running" bar above the composer is currently no longer usable bc it doesn't display much").
  // A narrow pane names only the newest; the rest are a count. Open, the lines name them.
  const named = !open && foldHead !== "counts" && newest.length > 0;
  const shownNames = named ? newest.slice(0, foldHead === "one" || oneName ? 1 : 2) : [];
  // The plan leads: its progress and the step at work, then what runs (Leo's hat, 2026-11-03).
  const planText = planned ? (planEarlier ? earlierPlanHead(t, plan) : planHead(t, plan)) : "";
  const workText = items.length + finished.length === 0 ? "" : named ? shownNames.join(" · ") : title;
  const headText = [planText, workText].filter(Boolean).join(" · ");
  const moreCount = items.length - shownNames.length;
  // Keep live and ended cards in one keyed child list. When a task completes, its card moves
  // between groups without remounting, so keyboard focus and the open affordance stay put.
  // Ended, cancelled (motion turned off midway) or unmounted first (a fold), a line's
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
  // What waits on the person or failed leads (trayAttention.ts), so the list's cap never hides it.
  let firstFinished = true;
  const cards = fold.present
    ? ordered.map(({ item, finished: ended }) => {
        const first = ended && firstFinished;
        if (ended) firstFinished = false;
        return (
          <li
            key={itemKey(item)}
            data-finished={ended ? "" : undefined}
            data-first-finished={first || undefined}
            {...arriving(itemKey(item))}
          >
            {line(item)}
          </li>
        );
      })
    : [];
  // The header's mark is in the accent while anything under it runs.
  const runs = running > 0 || commands > 0 || planned;
  return (
    <section
      ref={setTrayRef}
      className="acpmux-running-tray"
      aria-label={t("summary.subagents")}
      data-open={open || undefined}
      data-placement={placement}
      data-look={look}
      data-row={row}
      // Nothing runs: the ended lines sit quietly over the composer in the settled surface, joined to
      // the composer's top as one glass (no card of its own floating over it; Leo, 2026-10-31, on a
      // finished one-line row in a bordered card: "why is this still so ass").
      data-settled={(items.length === 0 && !planned) || undefined}
      // A headed tray keeps its own surface, settled too: a slightly lighter or darker glass than the
      // chat behind it and a hairline rim (Leo, 2026-11-01: "you can't just have it be the exact same
      // glass as the background"). traySurface.experiment.ts holds the arms.
      data-headed={headed || undefined}
      data-surface={surface}
      // It draws a card (and joins the composer as one glass, bottomStack.css): always while something
      // runs, and settled in every arm with a surface, a lone ended line too, so the transcript never
      // shows through it (Leo, 2026-11-02, on a done line over a reply's footer icons: "this running
      // thing now looks mildly awkward").
      data-card={items.length > 0 || planned || surface !== "none" || undefined}
      data-motion={motion}
      data-narrow={narrow || undefined}
      data-head={head}
      data-stop={stopLook}
      data-opens={(headed && opensPanel) || undefined}
      data-tucks={onTuck ? tuckSide : undefined}
      style={gutter > 0 ? ({ "--acpmux-tray-gutter": `${gutter}px` } as CSSProperties) : undefined}
    >
      {headed && (
        <button
          type="button"
          ref={headButton}
          className="acpmux-summary-row acpmux-summary-link acpmux-running-tray__head"
          aria-expanded={opensPanel === "header" ? undefined : open}
          aria-controls={open && opensPanel !== "header" ? listId : undefined}
          onClick={() => {
            if (opensPanel === "header") {
              onOpenPanel?.();
              return;
            }
            setOpened(!open);
            rememberTrayOpen(chat, !open);
          }}
        >
          {head === "stack" && drawnMarks.length > 0 ? (
            // The lines' own marks side by side, each subagent's in its tone (trayHead.experiment.ts),
            // as the sidebar's status row stacks them before "8 done".
            <span className="acpmux-running-tray__stack" data-tray-stack aria-hidden="true">
              {drawnMarks.map((mark) => (
                <AgentIdentity
                  key={mark.key}
                  className="acpmux-running-tray__stack-mark"
                  harness={mark.harness}
                  tone={mark.tone}
                  size={ROW_ICON}
                  fallback={mark.icon}
                />
              ))}
            </span>
          ) : (
            // The `bare` arm: the slot stays, blank, so the counts keep the lines' text column
            // (desktop.css --grid-tray-text) instead of jumping to the inset.
            <span
              className="acpmux-lineage__icon"
              data-state={runs ? "running" : "done"}
              // An empty stack (a plan with nothing running) keeps the slot blank, never the ring.
              data-blank={head === "bare" || head === "stack" || undefined}
              aria-hidden="true"
            >
              <Icon name={head === "session" ? "agent.session" : HEAD_ICON} size={ROW_ICON} row />
            </span>
          )}
          <Tick className="acpmux-summary-text acpmux-running-tray__title" text={headText} steadyCounts />
          {/* Open (or in the counts arm), what ended failed, in the danger colour, and a subagent of
              another model family by its harness's mark, as its line draws it. */}
          {!named && counts.failed > 0 && (
            <span className="acpmux-running-tray__failed">
              {title && <span aria-hidden="true">· </span>}
              {t("summary.subagents.failed", { n: counts.failed })}
            </span>
          )}
          {/* A family the stacked marks already draw is not drawn again here. */}
          {!named && trailingMarks.length > 0 && (
            <span className="acpmux-running-tray__marks" data-tray-marks>
              {trailingMarks.map((harness) => (
                <AgentMark key={harness} agent={harness} size={ROW_ICON} label={harness} />
              ))}
            </span>
          )}
          {named && moreCount > 0 && (
            <span className="acpmux-summary-meta acpmux-running-tray__more">{t("tools.more", { n: moreCount })}</span>
          )}
          {/* Quiet meta right after the counts, never a column of its own far from them. */}
          <span className="acpmux-summary-meta acpmux-running-tray__time" aria-hidden={starts.length === 0}>
            {starts.length > 0 ? formatDuration(Math.max(0, now - Math.min(...starts))) : undefined}
          </span>
          {/* The panel button's room, in the lines' Stop column: the button lies over it, outside the
              header's own button (a button holds no button). */}
          {opensPanel === "button" && <span className="acpmux-running-tray__open-slot" aria-hidden="true" />}
          {/* The one trailing column every line's chevron ends in. */}
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
          {/* The plan's checklist over what runs, the turn's own work first. */}
          {planned && (
            <div className="acpmux-running-tray__plan">
              <PlanList entries={plan} earlier={planEarlier} />
            </div>
          )}
          <ul ref={listRef} id={listId} className="acpmux-running-tray__list">
            {cards}
          </ul>
        </div>
      )}
      {onTuck && (
        <button
          type="button"
          className="acpmux-running-tray__tuck"
          aria-label={t("tray.tuck")}
          title={t("tray.tuck")}
          onClick={onTuck}
        >
          <Icon name="disclosure.expanded" size={12} />
        </button>
      )}
      {headed && opensPanel === "button" && (
        <button
          type="button"
          className="acpmux-running-tray__open"
          aria-label={t("backgroundTasks.open")}
          title={t("backgroundTasks.open")}
          onClick={onOpenPanel}
        >
          <Icon name="panel.right" size={ROW_ICON} row />
        </button>
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
          // Its task, as Claude Code's and ChatGPT's task rows read; its name moves to the tooltip.
          name={subagentTaskLabel(t, item.agent)}
          progress={subagentProgress(t, language, item.agent, { usage: false }).join(" · ") || undefined}
          progressAgent={item.agent}
          icon={SUBAGENT_FALLBACK}
          mark={foreignHarness(item.agent.harness, chatHarness)}
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
          label={t("subagents.open", { name: subagentTaskLabel(t, item.agent) })}
          chevron
          trayColumns
          // A narrow tray's workflow progress wraps under the title, above its time and controls.
          progressAt={row === "below" || narrow ? "below" : "meta"}
          // What it did last, on its own quiet line (Leo, 2026-11-03: "Tray only, richer").
          latest={latestAt === "tooltip" ? undefined : latestLine(t, item.agent, awaitsOwnWork(item.agent))}
          latestAt={latestAt === "inline" ? "inline" : "below"}
          onOpen={() => onOpen(item.agent.id)}
          after={
            stop &&
            item.agent.state === "running" &&
            !item.agent.command && <StopButton agent={item.agent} stop={stop} solid />
          }
        />,
        // An agent a shell call started stops with that call, not through the harness.
        stop &&
          item.agent.state === "running" &&
          !item.agent.command &&
          stopItem(
            stopKey(item)!,
            subagentDisplayName(t, item.agent),
            t("subagents.stop", { name: subagentDisplayName(t, item.agent) }),
            () => stop(item.agent.id),
          ),
      );
    if (item.kind === "command") {
      const key = itemKey(item);
      const processId = item.command.processId;
      // Named in words (session-info/commandRules.ts); the command as typed is its tooltip and the
      // first line of its tail.
      // A rule's mark where one reads the command (commandRules.ts), else the mark of the kind the
      // header counts it under (trayCommandKinds.ts), in place of the word Command.
      const read = commandRead(
        t,
        item.command,
        COMMAND_KIND_ICON[commandKind(item.command.command)],
        currentCommandRules(),
      );
      // A subagent's command says whose it is: "Reviewer · Waiting 14m · hold".
      const named = sendLabel(t, item.command) ?? read.label;
      return (
        <>
          {menu(
            <AgentLine
              name={item.owner ? `${subagentDisplayName(t, item.owner)} · ${named}` : named}
              title={item.command.command}
              chevron
              icon={read.icon}
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
                    solid
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
            open={openCommands.has(key) && (canReadTail || read.link !== undefined)}
            readOutput={canReadTail}
            link={read.link}
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

/// What the line no longer says, in its tooltip: its whole task (the line may cut it), its name
/// when the line shows its task instead, its kind (Explore, general-purpose) and, while it runs,
/// what it does now.
function agentTooltip(t: Translate, agent: Subagent): string | undefined {
  const doing =
    agent.state !== "running" ? undefined : agent.actionShell ? toolDetail(t, agent.action, true) : agent.action;
  const label = subagentTaskLabel(t, agent);
  const name = subagentDisplayName(t, agent);
  const lines = [
    agent.task,
    name !== label && name !== agent.task ? name : undefined,
    agent.kind && agent.kind !== agent.name ? agent.kind : undefined,
    doing,
  ];
  return lines.filter((line): line is string => Boolean(line)).join("\n") || undefined;
}

/// What each running item is called, newest first: a subagent by its task, a command by its
/// description or its words (session-info/commandRules.ts `commandRead`), a chat by its title. An item with
/// no start time sorts after those with one, in its list order.
/// At most the newest two are named (the default arm names one), so a long list costs a sort of its
/// start times, never a label per item.
function newestNames(t: Translate, items: readonly TrayItem[]): readonly string[] {
  return items
    .map((item, index) => ({ item, index, start: itemStart(item) ?? Number.NEGATIVE_INFINITY }))
    .sort((a, b) => b.start - a.start || a.index - b.index)
    .slice(0, 2)
    .map(({ item }) =>
      item.kind === "agent"
        ? subagentTaskLabel(t, item.agent)
        : item.kind === "command"
          ? (sendLabel(t, item.command) ?? commandRead(t, item.command, undefined, currentCommandRules()).label)
          : item.session.title,
    );
}

type HeadMark = { key: string; harness?: string; tone?: number; icon: string };
const NO_MARKS: readonly HeadMark[] = [];
/// How many lines' marks the header stacks; the counts after them say the rest.
const STACK_MARKS = 4;

/// The marks the header stacks (the `stack` arm): the first lines' own glyphs, what runs first, then
/// what ended. A subagent draws its subagent mark in its tone, or another family's harness mark; a
/// chat its harness's; a command its command icon. Computed when the lists change, never per tick.
function stackMarks(
  t: Translate,
  items: readonly TrayItem[],
  finished: readonly TrayItem[],
  chatHarness: string | undefined,
): readonly HeadMark[] {
  const marks: HeadMark[] = [];
  for (const item of [...items.slice(0, STACK_MARKS), ...finished.slice(0, STACK_MARKS)]) {
    if (marks.length === STACK_MARKS) break;
    marks.push(
      item.kind === "agent"
        ? {
            key: itemKey(item),
            harness: foreignHarness(item.agent.harness, chatHarness),
            tone: agentTone(item.agent.id),
            icon: SUBAGENT_FALLBACK,
          }
        : item.kind === "command"
          ? { key: itemKey(item), icon: commandRead(t, item.command).icon }
          : {
              key: itemKey(item),
              harness: item.session.harness,
              tone: agentTone(item.session.sessionId),
              icon: "agent.chat",
            },
    );
  }
  return marks;
}

/// The header's fixed mark for background work (trayHead.experiment.ts): a running ring, never the
/// chat bubble, which reads as a message, and never the spinner, which each working line keeps.
const HEAD_ICON = "app.sample.runningagents";

/// The header's plan part: "2 of 5 · Write the tests", the step at work (else the next one waiting)
/// after the progress; a list all done reads only its progress.
export function planHead(t: Translate, plan: readonly AcpmuxPlanEntry[]): string {
  const done = plan.filter((entry) => entry.status === "completed").length;
  const progress = t("plan.hat", { done, total: plan.length });
  const step = plan.find((entry) => entry.status === "in_progress") ?? plan.find((entry) => entry.status === "pending");
  return step ? `${progress} · ${step.content}` : progress;
}

/// The header's plan part for an earlier turn's list: "Earlier plan · 2 of 5", naming no step, as
/// none is at work in this turn.
export function earlierPlanHead(t: Translate, plan: readonly AcpmuxPlanEntry[]): string {
  const done = plan.filter((entry) => entry.status === "completed").length;
  return `${t("plan.earlier.short")} · ${t("plan.hat", { done, total: plan.length })}`;
}
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
