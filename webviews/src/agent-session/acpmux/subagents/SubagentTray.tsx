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
// Every tray gets a header first, one item too (Leo, 2026-11-07: a lone line that opened its subagent
// on the first click "instead of expanding it"; folded, a lone item's header names it, what it does
// now and its time, `loneHeadOf`), as the Codex and Claude desktop apps head their running agents: a still running-work mark (never the spinner, which stays on each
// working line, #27103), "2 subagents · 1 command", the time since the first started as
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
// A line says what the agent does now in words; command rows keep their actual shell command as
// the dim activity line so a monitor's work is identifiable at a glance.
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
import { HatChevron } from "./HatChevron";
import {
  type CSSProperties,
  type FocusEvent,
  memo,
  type KeyboardEvent as ReactKeyboardEvent,
  type PointerEvent as ReactPointerEvent,
  type ReactElement,
  type ReactNode,
  useCallback,
  useContext,
  useEffect,
  useId,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import { experimentArm } from "../../../experiments/experiment";
import { ContextMenu, type ContextMenuItem } from "../../../ui/ContextMenu";
import { Button } from "../../../ui/Button";
import { Tooltip } from "../../../ui/Tooltip";
import { foldMotion, useFold } from "../conversation/fold";
import { entranceAllowed } from "../../shared/pageReveal";
import { type PaneLanguage, usePaneLanguage, useT, type Translate } from "../i18n";
import { Icon } from "../icons/Icon";
import { rowIconSize } from "../icons/iconSize";
import { type BackgroundCommand, sendLabel } from "../session-info/processes";
import { commandRead } from "../session-info/commandRules";
import { ROW_WIDTH, trimRawCommand } from "../conversation/shortCommand";
import { currentCommandRules } from "../session-info/commandLabelSettings";
import { StopButton as ProcessStopButton } from "../session-info/TasksSection";
import {
  STATUS_LABEL,
  type SubagentStatus,
  subagentStateText,
  subagentStatus,
} from "../summary/subagentStatusListModel";
import { retrying, sessionRetry, retryWords, sessionRetryKey, type RetryQuiet } from "./retryState";
import { useConnectionQuietKeys } from "../../../ui/lasting";
import { AgentMark } from "../../shared/AgentMark";
import { AgentLine } from "./AgentLine";
import { AgentIdentity } from "./AgentIdentity";
import { SUBAGENT_FALLBACK } from "./agentIdentityModel";
import { harnessFamily } from "./agentRuns";
import { agentTone } from "./agentTones";
import { subagentProgress } from "./subagentProgress";
import { useAgentProgress } from "./agentProgressStore";
import { subagentDisplayName, subagentTaskLabel } from "./subsessions";
import { BackgroundTaskTail } from "./BackgroundTaskTail";
import { TrayAgentDetail, TrayLineFold } from "./TrayLineDetail";
import { StopButton } from "./SubagentGroup";
import { ResumeControl, type ResumeActions } from "./ResumeControl";
import { SubagentHarnessContext, ticking } from "./subagentGroupModel";
import { Elapsed } from "./Elapsed";
import { commandStatus, itemStart, trayItemKey, type TrayItem, SILENT_TURN_ICON } from "./runningTray";
import type { SilentTurn } from "../conversation/silentTurns";
import { backgroundTurnLabel } from "../conversation/backgroundTurns";
import { longestRunningFirst, runSince } from "./trayHeadOrder";
import { attentionFirst, type TrayCard } from "./trayAttention";
import { actionDetail, latestLine, namedAction } from "./trayDetail";
import { hatStepLook, type HatStepArm } from "./hatStep.experiment";
import { hatPhase, PHASE_DWELL_MS } from "./hatStep";
import { Dwelt, HatPhaseSlot, HatSampledSlot, useDwell } from "./HatStepSlot";
import { trayPanelLook, trayRowLook, trayStopLook } from "./trayPanel.experiment";
import { trayMotionLook } from "./trayMotion.experiment";
import { trayHeadLook } from "./trayHead.experiment";
import { hatFacesLook } from "./hatFaces.experiment";
import { HatFaces, hatFaces, type HatFace } from "./HatFaces";
import { type TrayFoldHeadArm, trayFoldHeadLook } from "./trayFoldHead.experiment";
import { trayOpenLook } from "./trayOpen.experiment";
import { trayHeadKindsLook } from "./trayHeadKinds.experiment";
import { trayHead, trayHeadGroups, trayHeadLine, trayHeadParts, type TrayHeadPart } from "./trayHeadKinds";
import { HeadSummary } from "./HeadSummary";
import { trayHeadHeightLook } from "./trayHeadHeight.experiment";
import { COMMAND_KIND_ICON, commandKind } from "./trayCommandKinds";
import { KIND_LINE_SEPARATOR, trayKindLineLook } from "./trayKindLine.experiment";
import { trayHeadClockLook } from "./trayHeadClock.experiment";
import { traySurfaceLook } from "./traySurface.experiment";
import { trayLatestLook } from "./trayLatest.experiment";
import { hatDoneLook } from "./hatParts.experiment";
import { hatOpenLook } from "./hatOpen.experiment";
import { SubagentCardBody, SubagentPreviewCard } from "./SubagentPreview";
import "./hatOpen.css";
import { deckOf, hatHeaderLook, hideOf } from "./hatHeader.experiment";
import { type HatLineArm, hatLineLook } from "./hatLine.experiment";
import { HatHeadDeck } from "./HatHeadDeck";
import "./hatHeader.css";
import { DoneMark } from "./DoneMark";
import { Tick, useGlide, GlideRow } from "./trayMotion";
import { useCountedRender } from "../perfRender";
import { useTrayMotion } from "./trayMotionModel";
import { useTraySeen } from "./traySeen";
import type { StartedSession } from "../started/startedSessions";
import { awaitsOwnWork, type Subagent } from "./subagentFold";
import type { SubagentTrayPlacement } from "./subagentTrayPlacement";
import { rememberTrayOpen, trayOpenFor } from "./trayFoldMemory";
import { HAT_OPEN_SLOP, hatDragEnd, hatDragHeight, setHatHeight, useHatHeight } from "./trayResize";
import type { TrayHandleSide } from "../chatDisplay";
import { focusRingShown } from "../../../ui/focusModality";
import { focusRoute } from "../../../ui/focusRoute";
import { RESIZE_HANDLE_PROPS } from "../../../scrollers";

const ROW_ICON = rowIconSize(12);

const itemKey = trayItemKey;

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
  canReadTail = false,
  canOpenTerminal = true,
  onOpenSession,
  onOpenPanel,
  stop,
  stopProcess,
  resume,
  placement = "tray",
  shown,
  stepLook,
  foldHeadLook,
  lineDeckLook,
  enters = false,
  chat,
  onTuck,
  tuckSide = "middle",
  onHold,
  onSeen,
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
  /// A connected local process source is available for the expanded tail.
  canReadTail?: boolean;
  /// The host opens a command's terminal (App.tsx `opensProcessTerminal`). Where it does not, the
  /// expanded tail shows no Open in terminal: there it would only reveal the command's call, and the
  /// tail already shows the command.
  canOpenTerminal?: boolean;
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
  /// Resume on a stopped subagent's finished line (ResumeControl.tsx): the chat's `resumeAgent`,
  /// as the transcript's end line has it. The tray sits outside the transcript's TurnActionsContext.
  resume?: ResumeActions;
  /// The default is the existing bottom tray; the alternate is fixture/Labs-driven.
  placement?: SubagentTrayPlacement;
  /// The chat on screen, as of the latest render (App.tsx): the tray plays its exit only when it
  /// goes while its chat still shows (trayMotion.tsx `useTrayMotion`); none, no entrance or exit.
  shown?: { readonly current: string | undefined };
  /// The hat-step arm, pinned: a gallery stage about one arm's look (the exact step's roll in
  /// StatusSwapStage.tsx) keeps it when the default moves. Else the experiment's arm.
  stepLook?: HatStepArm;
  /// The folded header's arm a stage pins (trayFoldHead.experiment.ts), over the experiment's.
  foldHeadLook?: TrayFoldHeadArm;
  /// The one-line hat's marks arm, pinned (a gallery stage or test about one arm). Else the experiment's.
  lineDeckLook?: HatLineArm;
  /// The tray appears in a chat that showed without it: it eases in.
  enters?: boolean;
  /// The chat the tray belongs to: the person's open or fold holds for it (trayFoldMemory.ts).
  chat?: string;
  /// Tucks the hat away to a pull tab on the composer's top edge (TrayPullTab.tsx): a chevron
  /// on the hat's own top edge, shown on hover (Leo, 2026-11-04: "at the top of the hat, there's
  /// some sort of little thing ... a special kind of chevron"). Unset, the hat can't tuck away.
  onTuck?: () => void;
  /// Where the tuck chevron sits along the hat's top edge, as the pull tab does along the composer's
  /// (chatDisplay.ts TRAY_HANDLE_KEY).
  tuckSide?: TrayHandleSide;
  /// The hat is held: open, or the pointer (or keyboard focus) is on it. App.tsx's linger
  /// (trayLinger.ts) expires no finished line while it is, and resumes when it lets go. Reported on
  /// a change only (never per pointer move), and false when the hat unmounts.
  onHold?: (held: boolean) => void;
  /// The hat could be seen: on screen, in a page that shows, in a focused window (traySeen.ts).
  /// App.tsx's linger counts a finished line's grace only while it could. Reported on a change only,
  /// and false when the hat stops drawing.
  onSeen?: (seen: boolean) => void;
}) {
  // Its committed renders while measuring (loadDebug.ts `loadTick` `still`): the hat over the composer
  // draws again on an event, never on the clock's tick.
  useCountedRender("tray");
  const t = useT();
  // A retry waits out the shared bound before its line says so (retryState.ts ``retryWords``).
  const connectionQuiet = useConnectionQuietKeys();
  const language = usePaneLanguage();
  // The chat's harness, for a subagent that names none (SubagentGroup.tsx `Avatar`).
  const chatHarness = useContext(SubagentHarnessContext);
  const listId = useId();
  // No clock here: each running time is its own leaf (Elapsed.tsx), so the clock's second draws one
  // text node per time, never the hat, its header or its lines (Leo, 2026-11-09: "im still sometimes
  // seeing a flicker on the composer/composer hat when scrolling and things are running in background
  // aka time is ticking").
  const trayNode = useRef<HTMLElement | null>(null);
  const [narrow, setNarrow] = useState(false);
  // Room for one name in the folded header, not two: a measured narrow tray (an unmeasured one, 0px,
  // keeps two).
  const [oneName, setOneName] = useState(false);
  // Folded until the person opens it; their choice holds for this chat (trayFoldMemory.ts).
  const [opened, setOpened] = useState<boolean | undefined>(() => trayOpenFor(chat));
  // The list height the person dragged the rim to (trayResize.ts), shared by every hat.
  const hatHeight = useHatHeight();
  // The lines open in place (TrayLineDetail.tsx): a click on a line expands it, never navigates.
  const [expanded, setExpanded] = useState<ReadonlySet<string>>(() => new Set());
  const toggleLine = useCallback(
    (key: string) =>
      setExpanded((current) => {
        const next = new Set(current);
        if (next.has(key)) next.delete(key);
        else next.add(key);
        return next;
      }),
    [],
  );
  // Each line's Stop, as its menu item: off while the request is out (and after it is taken, until
  // that run ends); when acpmux or the harness refuses, the item says so and can be tried again.
  const [stops, setStops] = useState<ReadonlyMap<string, "stopping" | "failed">>(() => new Map());
  // Read once per tray: the arm is the gallery's override or a dogfood key, never a per-tick read.
  const [look] = useState(() => experimentArm(trayPanelLook));
  const [motion] = useState(() => experimentArm(trayMotionLook));
  const [row] = useState(() => experimentArm(trayRowLook));
  const [head] = useState(() => experimentArm(trayHeadLook));
  const [surface] = useState(() => experimentArm(traySurfaceLook));
  const [foldHead] = useState(() => foldHeadLook ?? experimentArm(trayFoldHeadLook));
  const [facesArm] = useState(() => experimentArm(hatFacesLook));
  const [headHeight] = useState(() => experimentArm(trayHeadHeightLook));
  const [stopLook] = useState(() => experimentArm(trayStopLook));
  const [opensArm] = useState(() => experimentArm(trayOpenLook));
  const [headClock] = useState(() => experimentArm(trayHeadClockLook));
  const [kindsArm] = useState(() => experimentArm(trayHeadKindsLook));
  const [kindLine] = useState(() => experimentArm(trayKindLineLook));
  const [latestAt] = useState(() => experimentArm(trayLatestLook));
  // What a running subagent's line says it does now (hatStep.experiment.ts; Leo, 2026-11-22: "we dont
  // show the exact calls, ever, at the top").
  const [stepArm] = useState(() => stepLook ?? (experimentArm(hatStepLook) as HatStepArm));
  const [doneLook] = useState(() => experimentArm(hatDoneLook));
  // How a line opens what it stands for (hatOpen.experiment.ts; Lawrence, 2026-11-20: "ui for opening
  // subagents is very confusing").
  const [openLook] = useState(() => experimentArm(hatOpenLook));
  // The top bar (hatHeader.experiment.ts; Leo, 2026-11-20: "thumb through them like a Rolodex or
  // whatever at the top"): a deck of marks to thumb through, and where the hide control sits.
  const [headerLook] = useState(() => experimentArm(hatHeaderLook));
  // The one-line hat's marks (hatLine.experiment.ts, design pass c-fadfd55bc5): the same deck, on the
  // line, and the hide control flush at the line's end.
  const [lineLook] = useState(() => lineDeckLook ?? experimentArm(hatLineLook));
  // The line the header names while the pointer is on its mark (HatHeadDeck.tsx); a pointer event
  // sets it, never the clock.
  const [peeked, setPeeked] = useState<string | undefined>(undefined);
  const showLatest = latestAt !== "tooltip";
  const latestPlacement = latestAt === "tooltip" ? undefined : latestAt;
  const agentsById = useMemo(
    () =>
      new Map(
        [...items, ...finished]
          .filter((item): item is Extract<TrayItem, { kind: "agent" }> => item.kind === "agent")
          .map((item) => [item.agent.id, item.agent] as const),
      ),
    [items, finished],
  );
  // How the header reaches the Background tasks panel, where the chat has one (Leo, 2026-11-03: "a
  // thing like this that can either expand OR open up to this sort of thing"): a panel button beside
  // its chevron (the default), or the whole header, Claude's chip.
  const opensPanel = onOpenPanel && opensArm !== "none" ? opensArm : undefined;
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
  // The header stays while the tray has a line, running or ended: one of two running ending never
  // takes it (and its collapse) away.
  // One item heads the hat as several do (Leo, 2026-11-07: "when I click into it and it's only the one
  // sub-agent, like the fact that it immediately brings me over to the sub-agent instead of expanding
  // it is, like, ooh"): folded, the header names it, says what it does now and its time; a click
  // expands the hat in place, and the line inside opens it. The first click never navigates.
  const lone = items.length + finished.length === 1 ? (items[0] ?? finished[0]) : undefined;
  const headed = items.length + finished.length > 0;
  // A header that opens the panel never expands in place.
  const open = !headed || (opened === true && opensPanel !== "header");
  // The `hide` arm (hatOpen.experiment.ts): a headed hat hides from a button in its header, not the top edge.
  const hidesInHead = Boolean(onTuck) && headed && openLook === "hide";
  // The `eye`, `pill` and `bar` arms (hatHeader.experiment.ts): the hide control's own place in the top
  // bar, instead of today's tab on the top edge.
  // The one-line hat draws no hide eye of its own (Leo, 2026-11-27: "remove the hide eye icon"): on its
  // card it tucks from the top edge's tab, as the other headers do.
  const hideAt = onTuck && headed && !hidesInHead ? hideOf(headerLook) : undefined;
  // The list opens and folds on the shared fold, its height only (no fade in), from the header's
  // chevron.
  // A fold while the page is away (hidden, or in its first frames back) applies at once: the shared
  // page-reveal gate (shared/pageReveal.ts), read only when the fold changes.
  const fold = useFold(open, entranceMayRun, false);
  // A fold makes the list inert under a focused line or Stop: focus moves to the header that folded
  // it, never to the page's body. With no
  // motion the fold leaves in the same commit and takes the focused line with it, so whether focus
  // was in the list is kept as it moves (onFocus/onBlur below), not read after the commit.
  const headButton = useRef<HTMLButtonElement | null>(null);
  // "+N more" and the time move as one trailing segment: a width change before them glides them to
  // their new place instead of jumping (trayMotion.tsx `useGlide`). So do the counts after the
  // subagent icons (HatFaces.tsx): the icons' row takes its new width at once, and the words after
  // it glide on transform, never by an eased layout width (the feel harness's layout-shift check);
  // the icons' own held count starts that glide in its own commit (GlideRow, HatFaces.tsx).
  const headGlide = useGlide(
    headButton,
    ":scope > .acpmux-running-tray__more, :scope > .acpmux-running-tray__time, :scope > .acpmux-running-tray__kinds > :not(.acpmux-hat-faces)",
  );
  const focusInList = useRef(false);
  useLayoutEffect(() => {
    if (open || !focusInList.current) return;
    focusInList.current = false;
    const tray = trayNode.current;
    const focused = tray?.ownerDocument.activeElement;
    // Fell to the page (the line left with the fold), or still in the tray (an inert line): only
    // then. Focus the person put elsewhere since stays where it is.
    const fell = !focused || focused === tray?.ownerDocument.body;
    if ((fell || tray?.contains(focused)) && focused !== headButton.current)
      focusRoute(headButton.current, "system", "the subagent tray changed");
  }, [open]);
  // Held while open, or while the pointer or keyboard focus is on it (Leo, 2026-11-07: "if you have
  // things expanded and you're looking at them, they shouldn't just disappear like that"). Enter and
  // leave only, never a pointer move. Pointer focus (a click on the header) is not a hold: it would
  // keep a folded hat held after the pointer left.
  const [hovered, setHovered] = useState(false);
  const [keyboardIn, setKeyboardIn] = useState(false);
  // The tuck chevron stays away from the moment the hat expands or folds until the pointer leaves it:
  // its hover reveal on the hat's top edge read as a stray chevron popping in while the hat moved
  // (Leo, 2026-11-08: "some elements in between"). Its keyboard focus still shows it.
  const [tuckQuiet, setTuckQuiet] = useState(false);
  const held = (headed && open) || hovered || keyboardIn;
  const holdTo = useRef(onHold);
  useLayoutEffect(() => {
    holdTo.current = onHold;
  });
  useEffect(() => {
    holdTo.current?.(held);
  }, [held]);
  useEffect(
    () => () => {
      holdTo.current?.(false);
    },
    [],
  );
  useTraySeen(trayNode, headed, onSeen);
  // A line that joins the open list grows in from 0 height and a line that leaves keeps its node and
  // folds to 0 height (`TrayRow`, on the shared fold), so the lines around it move with it, never a
  // pop or a jump (Leo, 2026-11-07: "the things coming, they shouldn't just, like, pop in, burst in,
  // like, appear instantly, and, like, disappear instantly"). The lines it was drawn with, and lines
  // a fold brings back, are simply there. With no motion (Reduce Motion, the host's switch, a page
  // away: hidden, or in its first frames back, shared/pageReveal.ts) lines come and go at once. A
  // burst (more than ARRIVALS_PER_UPDATE lines at once, a reconnect's catch-up) is simply there or
  // gone too, as the transcript's live rows are, so the arrived and leaving sets stay a handful. The
  // lines are compared only when the tray's lists change (an event), never on the clock's tick, so a
  // long ended history costs nothing per second.
  const seen = useRef<ReadonlySet<string> | null>(null);
  const comparedFor = useRef<{ items: readonly TrayItem[]; finished: readonly TrayItem[] } | null>(null);
  const [arrived, setArrived] = useState<ReadonlySet<string>>(NO_ARRIVALS);
  // The lines leaving, each with its last card and where it was drawn; the open list's last drawn
  // lines, which a leaving line is taken from.
  const [leaving, setLeaving] = useState<ReadonlyMap<string, Leaving>>(NO_LEAVING);
  const drawnCards = useRef<readonly DrawnCard[]>([]);
  if (!fold.present && leaving.size > 0) setLeaving(NO_LEAVING);
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
    const fresh = [...keys].filter((key) => !known.has(key) && !leaving.has(key));
    const moves = open && fold.present && !foldMotion.reducedMotion() && entranceMayRun();
    if (fresh.length > 0 && fresh.length <= ARRIVALS_PER_UPDATE && moves)
      setArrived((current) => new Set([...current, ...fresh]));
    // A line that comes back while it leaves turns back where it is; one that leaves keeps its node.
    const back = [...leaving.keys()].filter((key) => keys.has(key));
    const left = [...known].filter((key) => !keys.has(key));
    const going =
      left.length > 0 && left.length <= ARRIVALS_PER_UPDATE && moves
        ? drawnCards.current.flatMap((drawn, index) =>
            !drawn.leaving && left.includes(drawn.key) ? [[drawn.key, { card: drawn.card, index }] as const] : [],
          )
        : [];
    if (back.length > 0 || going.length > 0)
      setLeaving((current) => {
        const next = new Map(current);
        for (const key of back) next.delete(key);
        for (const [key, value] of going) next.set(key, value);
        return next;
      });
  }
  /// A leaving line folded away: it unmounts.
  const gone = useCallback(
    (key: string) =>
      setLeaving((current) => {
        if (!current.has(key)) return current;
        const next = new Map(current);
        next.delete(key);
        return next;
      }),
    [],
  );
  /// A line's entrance has started: it never replays.
  const played = useCallback(
    (key: string) =>
      setArrived((current) => {
        if (!current.has(key)) return current;
        const next = new Set(current);
        next.delete(key);
        return next;
      }),
    [],
  );
  // What runs by name, newest first: computed when the items change (an event), never per tick.
  // The width the list's scrollbar takes, if it takes any (a classic, always-shown scrollbar): the
  // lines give it their end inset (subagents.css `--acpmux-tray-inset-end`), so their Stop and chevron
  // columns stay under the header's (Leo, 2026-11-03: "all that alignment can be done better ... the
  // chevrons with the stop symbols"), and the header never moves as the hat opens or folds (Leo,
  // 2026-11-14: "don't do that for the composer hat"). One observer on the list while it is mounted;
  // it disconnects with the list.
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
  // The folded header leads with the longest-running item and keeps it until it ends; its clock is
  // the run's, which never goes back (trayHeadOrder.ts; Leo, 2026-11-11: "the animation system is so
  // borked and unintegrated").
  const leading = useMemo(() => longestRunningFirst(items), [items]);
  const newest = useMemo(() => leadNames(t, leading), [t, leading]);
  // Kept as state and moved on during render when the list changes (React's "adjust state while
  // rendering"), so a render reads the same clock the last one drew.
  const [runStart, setRunStart] = useState<number | undefined>(undefined);
  const since = runSince(runStart, items);
  if (since !== runStart) setRunStart(since);
  // A header over several items: no time (`none`, each line has its own), the longest still-running
  // item's (`running`), or the run's (`run`, before). Leo, 2026-11-22, on "… 5 stopped 1h 23m 25s":
  // "what the fuck are you timing man" (trayHeadClock.experiment.ts).
  const leadStart = leading[0] === undefined ? undefined : itemStart(leading[0]);
  const itemsSince = headClock === "run" ? since : headClock === "running" ? leadStart : undefined;
  const ordered = useMemo(() => attentionFirst(items, finished, waiting), [items, finished, waiting]);
  // A lone item's header draws its own mark, as its line does.
  const headMarks = useMemo(
    () => (head === "stack" || lone ? stackMarks(leading, finished, chatHarness) : NO_MARKS),
    [head, lone, leading, finished, chatHarness],
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
  // Each kind's mark and count (the `kinds` arm), folded and open; hovering one names what it counts.
  // The `groups` arms (the default) count two kinds: subagents, and everything else backgrounded.
  const groupsHead = foldHead === "groups" || foldHead === "group-marks";
  const headParts = useMemo(
    () =>
      groupsHead
        ? trayHeadGroups(t, { items, finished, waiting }, chatHarness)
        : foldHead === "kinds" || foldHead === "tally" || foldHead === "summary"
          ? trayHeadParts(t, { items, finished, waiting }, foldHead !== "kinds", chatHarness)
          : NO_PARTS,
    [groupsHead, foldHead, t, items, finished, waiting, chatHarness],
  );
  // The `line` arm (the default): one plain sentence, "10 subagents working, 2 background commands
  // running", as Claude Code's (trayHeadKinds.ts `trayHeadLine`).
  const lineHead = foldHead === "line";
  const lineText = useMemo(
    () => (lineHead ? trayHeadLine(t, { items, finished, waiting }) : ""),
    [lineHead, t, items, finished, waiting],
  );
  // One icon per subagent in the kinds header, each naming its own (HatFaces.tsx).
  const faces = useMemo(
    () => (foldHead === "kinds" && facesArm !== "lead" ? hatFaces(t, items, finished, chatHarness) : NO_FACES),
    [foldHead, facesArm, t, items, finished, chatHarness],
  );
  if (items.length === 0 && finished.length === 0) return null;
  // The `line` arm names no silent turn (trayHeadLine): a hat of only those has no words, so it draws
  // nothing rather than an empty line over the composer (chat-flow-shift-budget's compaction-steer:
  // the compaction's silent turn put a bare hat in at its end and pushed the transcript 75px).
  if (lineHead && lineText === "") return null;
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
  // Folded, the header is the one line above the composer, so it names what runs, as Claude Code's
  // running-tasks list does (trayFoldHead.experiment.ts; Leo, 2026-11-03: "the "running" bar above
  // the composer is currently no longer usable bc it doesn't display much"): longest-running first,
  // so a new item never takes the lead (trayHeadOrder.ts). A narrow pane names only the first; the
  // rest are a count. Open, the lines name them, newest first.
  // Expanding and folding a lone item's hat is one transition (Leo, 2026-11-08: "there's, like, some
  // elements in between and then things don't balance out"): its end (state and time) stays at the
  // row's end, open or folded, over the line's own time; its words slide over to the counts and its
  // muted step narrows away on the same clock, never popping out or in; the line grows in under it on
  // the shared fold.
  // The `tally` arm counts a lone running item as it counts several: its mark and 1, no step words
  // swapping in (Leo, 2026-11-23: "just like how the "running a command" is inherently bullshit, and the
  // swap-in animation for it is even more additional bullshit"). Only one with nothing left to count
  // (it ended done or stopped) keeps its own head.
  // The `summary` arm (the default) counts as the tally does, in words while they fit (HeadSummary.tsx).
  const summaryHead = (foldHead === "summary" || groupsHead) && headParts.length > 0;
  const tallyHead = (foldHead === "tally" || summaryHead) && headParts.length > 0;
  const loneEnd =
    lone && !tallyHead && !lineHead ? loneHeadOf(t, language, lone, waiting, showLatest, connectionQuiet) : undefined;
  const loneHead = loneEnd && !open ? loneEnd : undefined;
  // The `kinds` arm draws each kind's mark and count, folded and open; a lone item keeps its own head.
  const kindsHead = tallyHead || (foldHead === "kinds" && !loneEnd && headParts.length > 0);
  const named = !open && !loneHead && !kindsHead && !lineHead && foldHead !== "counts" && newest.length > 0;
  const shownNames = named ? newest.slice(0, foldHead === "one" || oneName ? 1 : 2) : [];
  const workText = lineHead ? lineText : loneHead ? loneHead.title : named ? shownNames.join(" · ") : title;
  // The `strip` and `cards` arms: the header's marks are one per running line, to thumb through. A lone
  // item's header already names it, so its one mark only opens it; with nothing running the header
  // keeps today's marks.
  // The one-line hat (hatLine.experiment.ts) draws its own deck: after the words (`trail`), or leading
  // them (`lead`, `cards`). Its sentence never names a lone item, so a lone mark peeks too.
  const lineDeck = lineHead && leading.length > 0 && lineLook !== "words" ? lineLook : undefined;
  const deck =
    leading.length > 0
      ? lineHead
        ? lineDeck && (lineDeck === "cards" ? "cards" : "strip")
        : deckOf(headerLook)
      : undefined;
  const peeks = Boolean(deck) && (!lone || lineHead);
  const peekItem = peeks && peeked !== undefined ? leading.find((item) => itemKey(item) === peeked) : undefined;
  // What the header says while a mark is pointed at: that line's name and latest step, as a lone
  // item's header says them. The bar keeps its height and its trailing columns; the words truncate.
  const peekHead = peekItem ? loneHeadOf(t, language, peekItem, waiting, true, connectionQuiet) : undefined;
  const headText = peekHead ? peekHead.title : workText;
  const headSince = itemsSince;
  const moreCount = items.length - shownNames.length;
  // Keep live and ended cards in one keyed child list. When a task completes, its card moves
  // between groups without remounting, so keyboard focus and the open affordance stay put.
  // A fully folded tray has only its header. Avoid building hundreds of hidden row
  // elements on each header clock tick; keep them while a close animation still plays.
  // What waits on the person or failed leads (trayAttention.ts), so the list's cap never hides it.
  // The lines leaving stay where they were drawn until their fold ends.
  const drawn = fold.present ? withLeaving(ordered, leaving) : NO_DRAWN;
  drawnCards.current = drawn;
  let firstFinished = true;
  const cards = drawn.map(({ key, card: { item, finished: ended }, leaving: going }) => {
    const first = ended && !going && firstFinished;
    if (ended && !going) firstFinished = false;
    return (
      <TrayRow
        key={key}
        rowKey={key}
        enters={arrived.has(key)}
        leaving={going}
        entered={played}
        gone={gone}
        finished={ended}
        first={first}
      >
        {line(item)}
      </TrayRow>
    );
  });
  // The header's click: it opens the panel (the `header` arm) or expands and folds the hat in place.
  const toggle = () => {
    if (opensPanel === "header") {
      onOpenPanel?.();
      return;
    }
    setTuckQuiet(true);
    setOpened(!open);
    rememberTrayOpen(chat, !open);
  };
  // A click on a deck's mark (HatHeadDeck.tsx) opens its line as the line's own open does: a subagent's
  // view, a started chat, a command's terminal. A line with nothing to open there opens the hat on it,
  // expanded in place.
  const openItem = (item: TrayItem) => {
    if (item.kind === "agent") return onOpen(item.agent.id);
    if (item.kind === "session" && onOpenSession) return onOpenSession(item.session.sessionId);
    if (item.kind === "command" && onOpenCommand && canOpenTerminal) return onOpenCommand(item.command);
    const key = itemKey(item);
    setExpanded((current) => (current.has(key) ? current : new Set([...current, key])));
    if (!open) toggle();
  };
  // The deck of marks to thumb through (HatHeadDeck.tsx), where the arm draws one.
  const headDeck = deck ? (
    <HatHeadDeck
      items={leading}
      chatHarness={chatHarness}
      look={deck}
      at={lineDeck === "trail" ? "trail" : "lead"}
      peeked={peekItem ? peeked : undefined}
      onPeek={peeks ? setPeeked : noPeek}
      onOpenItem={openItem}
    />
  ) : null;
  // The top rim drags the list taller or shorter (trayResize.ts): it stays under the cursor, settles
  // on each line's edge, lands on a whole line, and folds below half the first. A press that never
  // moves does nothing; a double-click goes back to the default five lines.
  const resizes = !(headed && opensPanel === "header");
  const onRimDown = (event: ReactPointerEvent<HTMLDivElement>) => {
    if (event.button !== 0) return;
    const listNode = () => trayNode.current?.querySelector<HTMLElement>(".acpmux-running-tray__list") ?? null;
    // The list in the height's own units (its content box, as `--acpmux-tray-list-height` caps it):
    // how tall it is now and where each line's bottom edge falls.
    const measure = (list: HTMLElement | null) => {
      if (!list) return { height: 0, edges: [] as number[] };
      const style = getComputedStyle(list);
      const padTop = parseFloat(style.paddingTop) || 0;
      const padBottom = parseFloat(style.paddingBottom) || 0;
      const origin = list.getBoundingClientRect().top + list.clientTop + padTop - list.scrollTop;
      const edges = [...list.children]
        .map((child) => Math.round(child.getBoundingClientRect().bottom - origin))
        .filter((edge, index, all) => edge > 0 && (index === 0 || edge > all[index - 1]!));
      return { height: Math.max(0, list.clientHeight - padTop - padBottom), edges };
    };
    const first = measure(open ? listNode() : null);
    const frame = { start: first.height, edges: first.edges, viewport: window.innerHeight };
    const startY = event.clientY;
    const rim = event.currentTarget;
    try {
      rim.setPointerCapture(event.pointerId);
    } catch {
      // A pointer the browser no longer tracks: the rim's own listeners still follow it.
    }
    event.preventDefault();
    let shown = open;
    // The height before the drag: a drag that folds the hat, or never moves past the slop, keeps it.
    const before = hatHeight;
    let dragged = false;
    let grown = 0;
    const move = (moved: PointerEvent) => {
      grown = startY - moved.clientY;
      if (!dragged && Math.abs(grown) < HAT_OPEN_SLOP) return;
      if (!dragged && !shown && grown < 0) return;
      if (!dragged) trayNode.current?.setAttribute("data-dragging", "");
      dragged = true;
      if (!shown && headed) {
        // Opened from folded: the list mounts at the height the cursor reached, then is measured.
        shown = true;
        setOpened(true);
        rememberTrayOpen(chat, true);
      }
      if (frame.edges.length === 0) frame.edges = measure(listNode()).edges;
      setHatHeight(hatDragHeight(frame, grown), false);
    };
    const end = (ended: PointerEvent) => {
      rim.removeEventListener("pointermove", move);
      rim.removeEventListener("pointerup", end);
      rim.removeEventListener("pointercancel", end);
      rim.removeEventListener("lostpointercapture", end);
      trayNode.current?.removeAttribute("data-dragging");
      // A press that never moved does nothing at all: no fold, no click on what the rim lies over.
      if (!dragged) return;
      if (ended.type === "pointerup") grown = startY - ended.clientY;
      const landed = hatDragEnd(frame, grown);
      if (landed.kind === "size") {
        setHatHeight(landed.height, true);
        return;
      }
      setHatHeight(before, false);
      if (landed.kind === "fold" && shown && headed) {
        setOpened(false);
        rememberTrayOpen(chat, false);
      }
    };
    rim.addEventListener("pointermove", move);
    rim.addEventListener("pointerup", end);
    rim.addEventListener("pointercancel", end);
    // The hat leaves mid-drag (its last line ended): the drag ends where it reached.
    rim.addEventListener("lostpointercapture", end);
  };
  // The header's mark is in the accent while anything under it runs.
  const runs = running > 0 || commands > 0;
  // A card (the tray's glass, joined to the composer), the one line's too: folded it is the line on its
  // own opaque backing, at the composer's row height (Leo, 2026-11-27: "add the opaque backing to it
  // again with proper size"). #56287 had dropped it for a bare line.
  const carded = items.length > 0 || surface !== "none";
  // The `line` arm: Esc tucks the open list back to its line, focus back on the line.
  const onKeyDown = (event: ReactKeyboardEvent<HTMLElement>) => {
    if (!lineHead || !open || !headed || event.key !== "Escape" || event.defaultPrevented) return;
    event.preventDefault();
    event.stopPropagation();
    toggle();
    focusRoute(headButton.current, "system", "the composer hat folded");
  };
  return (
    // oxlint-disable-next-line jsx-a11y/no-noninteractive-element-interactions -- Escape tucks the open list from anywhere inside it.
    <section
      ref={setTrayRef}
      className={`acpmux-running-tray${carded ? " ui-glass ui-glass-floats acpmux-stack-material" : ""}`}
      // It holds still while the chat streams, ticks and scrolls: only its times tick, in their own
      // text (Elapsed.tsx). The dev budgets warn otherwise (devkit/perfBudgets.ts `still-surface`).
      data-perf-still="hat"
      aria-label={t("summary.subagents")}
      data-open={open || undefined}
      data-placement={placement}
      data-look={look}
      data-row={row}
      // Nothing runs: the ended lines sit quietly over the composer in the settled surface, joined to
      // the composer's top as one glass (no card of its own floating over it; Leo, 2026-10-31, on a
      // finished one-line row in a bordered card: "why is this still so ass").
      data-settled={items.length === 0 || undefined}
      // A headed tray keeps its own surface, settled too: a slightly lighter or darker glass than the
      // chat behind it and a hairline rim (Leo, 2026-11-01: "you can't just have it be the exact same
      // glass as the background"). traySurface.experiment.ts holds the arms.
      data-headed={headed || undefined}
      data-surface={surface}
      // It draws a card (and joins the composer as one glass, bottomStack.css): always while something
      // runs, and settled in every arm with a surface, a lone ended line too, so the transcript never
      // shows through it (Leo, 2026-11-02, on a done line over a reply's footer icons: "this running
      // thing now looks mildly awkward").
      data-card={carded || undefined}
      // The `line` arm: the hat is one plain sentence on its card, at the chat's text size.
      data-line={lineHead || undefined}
      data-motion={motion}
      data-narrow={narrow || undefined}
      data-head={head}
      data-head-height={headHeight}
      data-stop={stopLook}
      data-opens={(headed && opensPanel) || undefined}
      data-tucks={onTuck ? tuckSide : undefined}
      data-open-look={openLook}
      data-header-look={headerLook === "today" ? undefined : headerLook}
      data-hide-at={hideAt}
      data-sized={(resizes && hatHeight !== undefined) || undefined}
      style={
        gutter > 0 || (resizes && hatHeight !== undefined)
          ? ({
              ...(gutter > 0 ? { "--acpmux-tray-gutter": `${gutter}px` } : {}),
              ...(resizes && hatHeight !== undefined ? { "--acpmux-tray-list-height": `${hatHeight}px` } : {}),
            } as CSSProperties)
          : undefined
      }
      data-tuck-quiet={(onTuck && tuckQuiet) || undefined}
      onPointerEnter={() => {
        setHovered(true);
        setTuckQuiet(false);
      }}
      onPointerLeave={() => {
        setHovered(false);
        setTuckQuiet(false);
      }}
      onKeyDown={onKeyDown}
      onFocus={(event) => setKeyboardIn(focusVisible(event))}
      onBlur={(event) => {
        const to = event.relatedTarget as Node | null;
        if (!to || !event.currentTarget.contains(to)) setKeyboardIn(false);
      }}
    >
      {hideAt === "bar" && (
        // The `bar` arm: a slim bar along the hat's top, over the header. A press hides the hat (the rim
        // over it passes a press that never dragged through to it); its eye-slash shows on hover.
        <Tooltip label={t("tray.tuck")}>
          <Button bare type="button" className="acpmux-hat-hide-bar" aria-label={t("tray.tuck")} onClick={onTuck}>
            {/* icon-scale-allow: the eye-slash rides inside the 10 px bar */}
            <Icon name="action.hide" size={10} />
          </Button>
        </Tooltip>
      )}
      {headed && (
        <button
          type="button"
          ref={headButton}
          className="acpmux-summary-row acpmux-summary-link acpmux-running-tray__head"
          data-lone={loneEnd ? "" : undefined}
          aria-expanded={opensPanel === "header" ? undefined : open}
          aria-controls={open && opensPanel !== "header" ? listId : undefined}
          onClick={toggle}
        >
          {/* The `pill` arm: the hide pill's room, leading the bar (the pill lies over it, outside the
              header's own button). */}
          {hideAt === "pill" && <span className="acpmux-hat-hide-slot" data-at="pill" aria-hidden="true" />}
          {lineHead ? (
            deck && lineDeck !== "trail" && headDeck
          ) : deck ? (
            headDeck
          ) : summaryHead ? (
            <HeadSummary
              t={t}
              parts={headParts}
              separator={KIND_LINE_SEPARATOR[kindLine]}
              markSize={ROW_ICON}
              mark={(part) => <KindMark part={part} chatHarness={chatHarness} />}
              nameOf={(item) => itemName(t, item)}
              countOnly={foldHead === "group-marks"}
            />
          ) : kindsHead ? (
            <HeadKinds
              t={t}
              parts={headParts}
              separator={KIND_LINE_SEPARATOR[kindLine]}
              chatHarness={chatHarness}
              tally={tallyHead}
              faces={
                !tallyHead && faces.length > 0 && facesArm !== "lead" ? (
                  <GlideRow value={headGlide}>
                    <HatFaces
                      faces={faces}
                      size={ROW_ICON}
                      narrow={narrow}
                      arm={facesArm}
                      onOpen={onOpen}
                      onOpenSession={onOpenSession}
                    />
                  </GlideRow>
                ) : undefined
              }
            />
          ) : (head === "stack" || lone) && drawnMarks.length > 0 ? (
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
                  plain
                />
              ))}
            </span>
          ) : (
            // The `bare` arm: the slot stays, blank, so the counts keep the lines' text column
            // (desktop.css --grid-tray-text) instead of jumping to the inset.
            <span
              className="acpmux-lineage__icon"
              data-state={runs ? "running" : "done"}
              // An empty stack keeps the slot blank, never the ring.
              data-blank={head === "bare" || head === "stack" || undefined}
              aria-hidden="true"
            >
              <Icon name={head === "session" ? "agent.session" : HEAD_ICON} size={ROW_ICON} row />
            </span>
          )}
          {/* Its words slide as a status line hands over: a new name joining, the lone item's task (Leo,
              2026-11-07); its counts roll in place (trayMotion.tsx `Tick`). */}
          {/* A deck takes the counts' place, so its words stay: the summary, or the pointed-at line's name. */}
          {(!kindsHead || deck) && (
            // Held at least PHASE_DWELL_MS, as the step is: twenty subagents joining in a burst is one
            // change of words, not twenty (Leo, 2026-11-22: "huge churn in numbers"; feel-composer-hat.test.ts).
            // A fold or unfold, or pointing at a deck's mark, is the reader's own change: keyed by it, the
            // words change at once.
            <Dwelt
              key={`${open ? "open" : "folded"}:${peekItem ? peeked : ""}`}
              value={headText}
              dwellMs={PHASE_DWELL_MS}
            >
              {(text) => (
                <Tick className="acpmux-summary-text acpmux-running-tray__title" text={text} steadyCounts slide />
              )}
            </Dwelt>
          )}
          {/* Kept while the hat is open, faded out in place (subagents.css), so it never leaves or comes
              back at once; it gives way to the counts first, so its room costs them nothing. */}
          {loneEnd?.agent && loneEnd.status === "running" && !loneEnd.retry && stepArm !== "exact"
            ? showLatest &&
              agentStep(stepArm, loneEnd.agent, loneEnd.latest, loneEnd.status, "acpmux-running-tray__latest")
            : loneEnd?.latest &&
              loneEnd.latest !== loneEnd.title && (
                <Tick
                  className={`acpmux-running-tray__latest${loneEnd.latestCode ? " is-code" : ""}`}
                  text={loneEnd.latest}
                  slide
                />
              )}
          {/* A pointed-at mark's latest step, after its name, as a lone item's header shows its own. */}
          {peekHead?.latest && peekHead.latest !== peekHead.title && (
            <Tick
              className={`acpmux-running-tray__latest${peekHead.latestCode ? " is-code" : ""}`}
              text={peekHead.latest}
              slide
            />
          )}
          {/* The one line's `trail` marks, after its words (hatLine.experiment.ts). */}
          {lineDeck === "trail" && headDeck}

          {loneHead?.agent && <LoneProgress agent={loneHead.agent} fallback={loneHead.progress} />}
          {/* Open (or in the counts arm), what ended failed, in the danger colour, and a subagent of
              another model family by its harness's mark, as its line draws it. */}
          {!named && !loneEnd && !peekHead && !kindsHead && counts.failed > 0 && (
            <span className="acpmux-running-tray__failed">
              {title && <span aria-hidden="true">· </span>}
              {t("summary.subagents.failed", { n: counts.failed })}
            </span>
          )}
          {/* A family the stacked marks already draw is not drawn again here. */}
          {!named && !loneEnd && !peekHead && !kindsHead && trailingMarks.length > 0 && (
            <span className="acpmux-running-tray__marks" data-tray-marks>
              {trailingMarks.map((harness) => (
                <AgentMark key={harness} agent={harness} size={ROW_ICON} label={harness} />
              ))}
            </span>
          )}
          {/* The rest of the names, one word space after them (subagents.css); its count rolls in place
              and its "+" sits on the figures' centre (Typography.tsx `Sign`). */}
          {named && !peekHead && moreCount > 0 && (
            <Dwelt key={open ? "open" : "folded"} value={moreCount} dwellMs={PHASE_DWELL_MS}>
              {(n) => (
                <Tick
                  className="acpmux-summary-meta acpmux-running-tray__more"
                  text={t("tools.more", { n })}
                  steadyCounts
                />
              )}
            </Dwelt>
          )}
          {/* Quiet meta right after the counts, never a column of its own far from them. */}
          {loneEnd ? (
            // A lone item's state and time end the row, where its line's would (AgentLine.tsx trail).
            // A failed or waiting one's state word takes its line's tone (summary.css): folded, the
            // header is all that says so.
            <span className="acpmux-summary-meta acpmux-running-tray__time" data-lone data-status={loneEnd.status}>
              {loneEnd.status === "done" ? (
                <DoneMark state={loneEnd.state} time={loneEnd.time} look={doneLook} checkInSlot />
              ) : loneEnd.status === "running" && !loneEnd.retry && since !== undefined ? (
                // The run's clock, not the item's own: left the one running after a longer one ended,
                // the header's time never goes back (trayHeadOrder.ts `runSince`; review of cmux#41078).
                <Elapsed since={since} />
              ) : loneEnd.status === "running" && !loneEnd.retry && loneEnd.time !== undefined ? (
                loneEnd.time
              ) : (
                <>
                  <span className="acpmux-running-tray__lone-state">{loneEnd.state}</span>
                  {loneEnd.time !== undefined && (
                    <>
                      {" · "}
                      {loneEnd.time}
                    </>
                  )}
                </>
              )}
            </span>
          ) : lineHead ? null : headSince !== undefined ? ( // The clock is the time element itself, so a range over it holds only its text.
            <Elapsed clock="acpmux-summary-meta acpmux-running-tray__time" since={headSince} />
          ) : (
            <span className="acpmux-summary-meta acpmux-running-tray__time" aria-hidden />
          )}
          {/* The panel button's room, in the lines' Stop column: the button lies over it, outside the
              header's own button (a button holds no button). */}
          {/* The `hide` arm (hatOpen.experiment.ts): the hide control's room in the header, one column
              before the panel button's, so it never sits where the expand chevron is. */}
          {hidesInHead && <span className="acpmux-running-tray__hide-slot" aria-hidden="true" />}
          {hideAt === "eye" && <span className="acpmux-hat-hide-slot" data-at="eye" aria-hidden="true" />}
          {opensPanel === "button" && (!lineHead || open) && (
            <span className="acpmux-running-tray__open-slot" aria-hidden="true" />
          )}
          {/* The one trailing column every line's chevron ends in. */}
          {!lineHead && (
            <span className="acpmux-running-tray__status">
              {/* It points the way the hat goes, up while folded (the hat opens upward from the composer),
                down while open, never a sideways arrow that reads as going somewhere (Leo, 2026-11-07,
                on a lone line that navigated on its first click). It stays at the row's end, in the
                lines' chevron column: a chevron centred on the hat's bottom edge (Leo, 2026-11-07: "I
                feel like the chevron for the composer hat would maybe be nicer at the bottom. Do you
                think? I'm not sure.") floated mid-row over the header in the gallery. */}
              <span className="acpmux-running-tray__chevron" data-open={open || undefined}>
                <HatChevron />
              </span>
            </span>
          )}
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
          <ul ref={listRef} id={listId} className="acpmux-running-tray__list">
            {cards}
          </ul>
        </div>
      )}
      {resizes && (
        // The rim's grabber, a thin band along the hat's top edge under the tuck chevron (which sits
        // later, so it keeps its own clicks). A pointer control only; the header stays the keyboard's.
        <div
          className="acpmux-running-tray__rim"
          {...RESIZE_HANDLE_PROPS}
          title={t("tray.resize")}
          aria-hidden="true"
          onPointerDown={onRimDown}
          onDoubleClick={() => setHatHeight(undefined, true)}
        />
      )}
      {hidesInHead && (
        // The `hide` arm: the header's own hide button, over its slot, shown while the pointer is on
        // the hat or it has keyboard focus; the top edge keeps only the resize rim.
        <Tooltip label={t("tray.tuck")}>
          <Button
            bare
            type="button"
            className="acpmux-running-tray__hide"
            data-with-panel={opensPanel === "button" || undefined}
            aria-label={t("tray.tuck")}
            onClick={onTuck}
          >
            <Icon name="action.hide" size={ROW_ICON} row />
          </Button>
        </Tooltip>
      )}
      {(hideAt === "eye" || hideAt === "pill") && (
        // The `eye` arm: a small eye-slash circle in the bar's trailing controls, shown at rest in muted
        // ink (never a hover-only control). The `pill` arm: a glass pill leading the bar, attached to the
        // hat's edge. Each lies over its slot in the header, outside the header's own button.
        <Tooltip label={t("tray.tuck")}>
          <Button
            bare
            type="button"
            className="acpmux-hat-hide"
            data-at={hideAt}
            data-with-panel={opensPanel === "button" || undefined}
            aria-label={t("tray.tuck")}
            onClick={onTuck}
          >
            <Icon name="action.hide" size={hideAt === "eye" ? 12 : ROW_ICON} row={hideAt !== "eye"} />
          </Button>
        </Tooltip>
      )}
      {onTuck && !hidesInHead && !hideAt && (
        <Tooltip label={t("tray.tuck")}>
          <Button bare type="button" className="acpmux-running-tray__tuck" aria-label={t("tray.tuck")} onClick={onTuck}>
            <Icon name="disclosure.expanded" size={12} />
          </Button>
        </Tooltip>
      )}
      {headed && opensPanel === "button" && (!lineHead || open) && (
        <Tooltip label={t("backgroundTasks.open")}>
          <Button
            bare
            type="button"
            className="acpmux-running-tray__open"
            aria-label={t("backgroundTasks.open")}
            onClick={onOpenPanel}
          >
            <Icon name="panel.right" size={ROW_ICON} row />
          </Button>
        </Tooltip>
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
    const key = itemKey(item);
    const isOpen = expanded.has(key);
    const toggleThis = () => toggleLine(key);
    // hatOpen.experiment.ts: `row` opens what every line stands for on its click and keeps the details
    // behind the chevron, its own button. `rolodex` previews every line in a card on hover; a subagent's
    // line opens it as today, and a command's or a chat's still expands in place, since its output, link
    // and Open chat do not fit a hover card.
    const opensRow = openLook === "row";
    const detailsButton = (can: boolean) =>
      openLook === "row" && can ? { open: isOpen, label: t("message.details"), onToggle: toggleThis } : undefined;
    const peek = openLook === "rolodex" ? "acpmux-hat-peek" : undefined;
    if (item.kind === "agent") {
      const parent = item.agent.parent === null ? undefined : agentsById.get(item.agent.parent);
      const agentLatest = latestLine(t, item.agent, awaitsOwnWork(item.agent));
      return (
        <>
          {menu(
            <AgentLine
              // Its task, as Claude Code's and ChatGPT's task rows read; its name moves to the tooltip.
              name={subagentTaskLabel(t, item.agent)}
              progress={subagentProgress(t, language, item.agent, { usage: false }).join(" · ") || undefined}
              progressAgent={item.agent}
              icon={SUBAGENT_FALLBACK}
              mark={item.agent.harness ?? chatHarness}
              tone={agentTone(item.agent.id)}
              plainMark
              doneLook={doneLook}
              status={subagentStatus(item.agent, waiting)}
              working={subagentStatus(item.agent, waiting) === "running"}
              state={subagentStateText(t, item.agent, waiting, connectionQuiet)}
              quiet={quietAgent(item.agent, waiting)}
              time={agentTime(item.agent)}
              depth={item.depth}
              // Its kind and what it does now are off the line (Leo, 2026-10-31: "a lot of these
              // subtitles are bad"); the tooltip keeps them under its task.
              title={agentTooltip(t, item.agent)}
              label={subagentTaskLabel(t, item.agent)}
              chevron
              trayColumns
              // A narrow tray's workflow progress wraps under the title, above its time and controls.
              progressAt={row === "below" || narrow ? "below" : "meta"}
              // What it did last, on its own quiet line (Leo, 2026-11-03: "Tray only, richer").
              latest={showLatest ? agentLatest : undefined}
              step={
                showLatest
                  ? agentStep(stepArm, item.agent, agentLatest, subagentStatus(item.agent, waiting))
                  : undefined
              }
              latestAt={latestPlacement}
              via={parent ? subagentTaskLabel(t, parent) : undefined}
              onOpen={() => onOpen(item.agent.id)}
              card={peek && <SubagentPreviewCard agent={item.agent} waiting={waiting} />}
              cardClassName={peek}
              disclose={detailsButton(true)}
              after={
                item.agent.state === "running"
                  ? stop && !item.agent.command && <StopButton agent={item.agent} stop={stop} solid />
                  : // A stopped one's Resume sits in Stop's column (Leo, 2026-11-12: "WHY CANT WE
                    // RESTART AGENTS THAT WERE STOPPED").
                    resume && <ResumeControl agent={item.agent} actions={resume} />
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
          )}
          {/* The `row` arm: its chevron shows its whole task and what it does now under the line. */}
          {openLook === "row" && (
            <TrayLineFold open={isOpen}>
              <TrayAgentDetail name={subagentTaskLabel(t, item.agent)} task={item.agent.task} latest={agentLatest} />
            </TrayLineFold>
          )}
        </>
      );
    }
    if (item.kind === "command") {
      // A finished command stays a while as done, failed or stopped, with how long it ran
      // (trayLinger.ts); only a running one stops.
      const status = commandStatus(item.command);
      const runs = status === "running";
      const processId = runs ? item.command.processId : undefined;
      const commandElapsed = commandTime(item.command);
      const ownerParent =
        item.owner?.parent === null || item.owner?.parent === undefined ? undefined : agentsById.get(item.owner.parent);
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
      const openTerminal = canOpenTerminal && onOpenCommand ? () => onOpenCommand(item.command) : undefined;
      return (
        <>
          {menu(
            <AgentLine
              name={item.owner ? `${subagentTaskLabel(t, item.owner)} · ${named}` : named}
              latest={showLatest ? trimRawCommand(item.command.command, ROW_WIDTH) : undefined}
              latestAt={latestPlacement}
              latestCode
              via={ownerParent ? subagentTaskLabel(t, ownerParent) : undefined}
              title={item.command.command}
              chevron
              icon={read.icon}
              working={runs}
              status={status}
              doneLook={doneLook}
              state={t(STATUS_LABEL[status])}
              quiet={runs || status === "done"}
              expanded={opensRow && openTerminal ? undefined : isOpen}
              trayColumns
              time={commandElapsed}
              // Expands to its tail where there is one to show: a host that reads its output or opens
              // its terminal, or a link it is about.
              onOpen={
                opensRow && openTerminal
                  ? openTerminal
                  : onOpenCommand || canReadTail || read.link
                    ? toggleThis
                    : undefined
              }
              card={
                peek && (
                  <SubagentCardBody
                    name={named}
                    status={status}
                    state={t(STATUS_LABEL[status])}
                    latest={item.command.command}
                  />
                )
              }
              cardClassName={peek}
              // Its own details button only where the row opens something else (its terminal) and the
              // details hold more than that: a row that only expands keeps today's one chevron, so no two
              // controls do the same thing.
              disclose={detailsButton(Boolean(openTerminal && (canReadTail || read.link || item.owner)))}
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
          <TrayLineFold open={isOpen}>
            <BackgroundTaskTail
              command={item.command}
              open
              readOutput={canReadTail}
              link={read.link}
              owner={item.owner ? subagentTaskLabel(t, item.owner) : undefined}
              elapsed={commandElapsed}
              // The row expands in place, so its terminal (or, where none opens, its call: App.tsx
              // `openTrayCommand`) is this explicit button now, never the row's click.
              onOpenTerminal={canOpenTerminal && onOpenCommand ? () => onOpenCommand(item.command) : undefined}
              // A subagent's command: the whole line, its title included, expands it, and the way to the
              // subagent is this explicit Open chat (Leo, 2026-11-07: "me clicking this, the entire box, it
              // just feels like, okay, I would be expanding this").
              onOpenOwner={item.owner && (() => onOpen(item.owner!.id))}
            />
          </TrayLineFold>
        </>
      );
    }
    if (item.kind === "turn") {
      // A silent turn (conversation/silentTurns.ts): a finished line in the command's row style, its
      // time, and opened, what it did and any words it kept to itself.
      const name = silentTurnName(t, item.turn);
      const steps = item.turn.steps.join("\n");
      return (
        <>
          <AgentLine
            name={name}
            chevron
            icon={SILENT_TURN_ICON}
            working={false}
            status="done"
            doneLook={doneLook}
            state={t(STATUS_LABEL.done)}
            quiet
            expanded={isOpen}
            trayColumns
            time={<Elapsed since={item.turn.startedAt} until={item.turn.endedAt} />}
            onOpen={steps || item.turn.reply ? toggleThis : undefined}
          />
          <TrayLineFold open={isOpen}>
            <TrayAgentDetail name={name} task={steps || undefined} latest={item.turn.reply} />
          </TrayLineFold>
        </>
      );
    }
    // The chat's retry, as every surface reads it (retryState.ts ``sessionRetry``).
    const sessionPhase = sessionRetry(item.session);
    const sessionRetrying = sessionPhase.kind === "retrying" ? sessionPhase.retry : undefined;
    const sessionState =
      retryWords(t, sessionRetrying, sessionRetryKey(item.session.sessionId), connectionQuiet) ??
      t(STATUS_LABEL[SESSION_STATUS[item.session.state]]);
    return (
      <>
        <AgentLine
          name={item.session.title}
          title={item.session.doing}
          mark={item.session.harness}
          tone={agentTone(item.session.sessionId)}
          plainMark
          chevron
          icon="agent.chat"
          status={sessionRetrying ? "running" : SESSION_STATUS[item.session.state]}
          working={sessionRetrying !== undefined || item.session.state === "running"}
          state={sessionState}
          quiet={!sessionRetrying && (item.session.state === "running" || item.session.state === "idle")}
          trayColumns
          expanded={opensRow && onOpenSession ? undefined : isOpen}
          // Only a line with something to show expands; one with nothing is a quiet, disabled line.
          onOpen={
            opensRow && onOpenSession
              ? () => onOpenSession(item.session.sessionId)
              : onOpenSession || item.session.doing
                ? toggleThis
                : undefined
          }
          card={
            peek && (
              <SubagentCardBody
                name={item.session.title}
                status={sessionRetrying ? "running" : SESSION_STATUS[item.session.state]}
                state={sessionState}
                latest={item.session.doing}
              />
            )
          }
          cardClassName={peek}
          // As a command's: a details button only where the row opens the chat and there is a step to show.
          disclose={detailsButton(Boolean(onOpenSession && item.session.doing))}
        />
        <TrayLineFold open={isOpen}>
          <TrayAgentDetail
            name={item.session.title}
            latest={item.session.doing}
            onOpen={onOpenSession && (() => onOpenSession(item.session.sessionId))}
          />
        </TrayLineFold>
      </>
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
    agent.state !== "running"
      ? undefined
      : agent.actionShell
        ? actionDetail(t, agent.action, true)
        : namedAction(t, agent.action);
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

/// What a lone item's folded header says (SubagentTray.tsx `lone`): its name as its line names it, what
/// it does now (as its line's latest), its status, its state word and its time.
type LoneHead = {
  title: string;
  latest?: string;
  latestCode?: boolean;
  status: SubagentStatus;
  state: string;
  /// Its time, ticking in its own leaf while it runs (Elapsed.tsx).
  time?: ReactNode;
  /// A retry is in progress: its words ("Retrying (2/4) ...") stay on the row, as its line says them.
  retry?: boolean;
  /// A subagent's workflow progress ("1/3 agents"), live from the progress store (AgentLine.tsx).
  agent?: Subagent;
  progress?: string;
};

/// A folded lone subagent's progress after what it does now, as its line says it: folded, the
/// header is all that shows it.
/// What a running subagent's line says it does now, by the hat-step arm: undefined keeps the line's
/// exact `latest` (the `exact` arm, and any line not running).
function agentStep(
  arm: HatStepArm,
  agent: Subagent,
  latest: string | undefined,
  status: string,
  className?: string,
): ReactNode | undefined {
  if (arm === "exact" || status !== "running") return undefined;
  if (arm === "quiet") return null;
  if (arm === "sampled") return latest ? <HatSampledSlot text={latest} className={className} /> : null;
  return <HatPhaseSlot phase={hatPhase(agent)} className={className} />;
}
function LoneProgress({ agent, fallback }: { agent: Subagent; fallback?: string }) {
  const progress = useAgentProgress(agent) ?? fallback;
  return progress ? <span className="acpmux-summary-meta acpmux-running-tray__stats">{progress}</span> : null;
}
function loneHeadOf(
  t: Translate,
  language: PaneLanguage,
  item: TrayItem,
  waiting: ReadonlySet<string>,
  showLatest: boolean,
  connectionQuiet: RetryQuiet,
): LoneHead {
  if (item.kind === "agent") {
    const status = subagentStatus(item.agent, waiting);
    const retry = retrying(item.agent) !== undefined;
    return {
      title: subagentTaskLabel(t, item.agent),
      latest:
        showLatest && status === "running" && !retry ? latestLine(t, item.agent, awaitsOwnWork(item.agent)) : undefined,
      status,
      state: subagentStateText(t, item.agent, waiting, connectionQuiet),
      time: agentTime(item.agent),
      retry,
      agent: item.agent,
      progress: subagentProgress(t, language, item.agent, { usage: false }).join(" · ") || undefined,
    };
  }
  if (item.kind === "command") {
    const status = commandStatus(item.command);
    return {
      title: sendLabel(t, item.command) ?? commandRead(t, item.command, undefined, currentCommandRules()).label,
      latest: showLatest && status === "running" ? trimRawCommand(item.command.command, ROW_WIDTH) : undefined,
      latestCode: true,
      status,
      state: t(STATUS_LABEL[status]),
      time: commandTime(item.command),
    };
  }
  if (item.kind === "turn")
    return {
      title: silentTurnName(t, item.turn),
      status: "done",
      state: t(STATUS_LABEL.done),
      time: <Elapsed since={item.turn.startedAt} until={item.turn.endedAt} />,
    };
  // The chat's retry, as its line reads it (retryState.ts `sessionRetry`): a failed turn that acpmux
  // retries reads as retrying, never Failed.
  const phase = sessionRetry(item.session);
  const retry = phase.kind === "retrying" ? phase.retry : undefined;
  const status = retry ? "running" : SESSION_STATUS[item.session.state];
  return {
    title: item.session.title,
    latest: showLatest && status === "running" && !retry ? item.session.doing : undefined,
    status,
    state: retryWords(t, retry, sessionRetryKey(item.session.sessionId), connectionQuiet) ?? t(STATUS_LABEL[status]),
    retry: retry !== undefined,
  };
}

/// What each running item is called, newest first: a subagent by its task, a command by its
/// description or its words (session-info/commandRules.ts `commandRead`), a chat by its title. An item with
/// no start time sorts after those with one, in its list order.
/// At most the newest two are named (the default arm names one), so a long list costs a sort of its
/// start times, never a label per item.
/// The first two names of `leading` (longest-running first, trayHeadOrder.ts).
function leadNames(t: Translate, leading: readonly TrayItem[]): readonly string[] {
  return leading.slice(0, 2).map((item) => itemName(t, item));
}

const NO_PARTS: readonly TrayHeadPart[] = [];
const NO_FACES: readonly HatFace[] = [];
/// How many names a kind's hover lists; the rest are a count.
const PART_NAMES = 8;

/// An item's name, as its line and the folded header name it.
function itemName(t: Translate, item: TrayItem): string {
  return item.kind === "agent"
    ? subagentTaskLabel(t, item.agent)
    : item.kind === "command"
      ? (sendLabel(t, item.command) ?? commandRead(t, item.command, undefined, currentCommandRules()).label)
      : item.kind === "turn"
        ? silentTurnName(t, item.turn)
        : item.session.title;
}

/// A silent turn's line (conversation/silentTurns.ts): what started it, as the transcript's
/// background-turn line names it ("Background update", "Scheduled check").
function silentTurnName(t: Translate, turn: SilentTurn): string {
  return turn.background ? backgroundTurnLabel(t, turn.background) : t("backgroundTurn.other");
}

/// The header's kinds (trayFoldHead.experiment.ts `kinds`): each kind's mark then its count, one gap
/// apart, the first mark in the lines' icon column (Leo, 2026-11-21: the open header's "1 message · 1
/// wait" "almost makes more sense to have at baseline", its icons "like before" to hover across).
/// Hovering a kind names what it counts; the names are read only on hover, never per tick.
function HeadKinds({
  t,
  parts,
  separator,
  chatHarness,
  tally,
  faces,
}: {
  t: Translate;
  parts: readonly TrayHeadPart[];
  /// The `tally` arm: each kind is its mark and its number, the kinds a gap apart with no words between.
  tally: boolean;
  /// Between the kinds (trayKindLine.experiment.ts), so the header reads as the counts did.
  separator: string;
  chatHarness: string | undefined;
  /// One icon per subagent before the counts (HatFaces.tsx); the subagents kind then draws no mark.
  faces?: ReactNode;
}) {
  return (
    <span
      className="acpmux-summary-text acpmux-running-tray__title acpmux-running-tray__kinds"
      data-tally={tally || undefined}
    >
      {faces}
      {parts.map((part, index) => (
        // A kind and the separator before it are one unit, so a kind that does not fit drops whole
        // onto the hidden second line, never cut mid-word (subagents.css; Leo, 2026-11-22: "this
        // should not be cutting off so harshly like this. we basically never want that kinda shit").
        <span key={part.key} className="acpmux-running-tray__kind-unit">
          {!tally && index > 0 && <span className="acpmux-running-tray__kind-sep">{separator}</span>}
          <HeadKind t={t} part={part} chatHarness={chatHarness} faced={faces !== undefined} tally={tally} />
        </span>
      ))}
    </span>
  );
}

function HeadKind({
  t,
  part,
  chatHarness,
  faced,
  tally,
}: {
  t: Translate;
  part: TrayHeadPart;
  chatHarness: string | undefined;
  /// The header draws each subagent's icon before the counts: this kind's own mark and names list go.
  faced: boolean;
  /// The `tally` arm: the mark and the number only; the words are the hover's and a reader's.
  tally: boolean;
}) {
  const [names, setNames] = useState<string | undefined>(undefined);
  // Its count changes at most once per dwell, as the step does: a burst of joins is one roll. The `tally`
  // arm's text is the number alone; the words are the hover's and a reader's.
  const kindText = useDwell(tally ? String(part.items.length) : part.text, PHASE_DWELL_MS);
  // A subagent kind draws its first subagent's harness mark, in its tone, as its line does (the
  // `tally` arm: one kind per harness, so its own harness's).
  const lead = part.items[0];
  const agent = part.key.startsWith("agents") && lead?.kind === "agent" ? lead.agent : undefined;
  // With the faces drawn, the subagents kind is words only; each face names its own subagent.
  const bare = faced && part.key === "agents";
  return (
    <span
      className="acpmux-running-tray__kind"
      data-kind={part.key}
      data-tone={part.tone}
      // tooltip-allow: the head draws the agents' marks only; the tooltip names them.
      title={bare ? undefined : names}
      aria-label={tally ? part.text : undefined}
      onPointerEnter={() => {
        if (bare || names !== undefined) return;
        const shown = part.items.slice(0, PART_NAMES).map((item) => itemName(t, item));
        const rest = part.items.length - shown.length;
        // The tally draws no words: its hover says what the number counts, then names them.
        setNames(
          [...(tally ? [part.text] : []), ...shown, ...(rest > 0 ? [t("tools.more", { n: rest })] : [])].join("\n"),
        );
      }}
    >
      {bare ? null : agent ? (
        <AgentIdentity
          className="acpmux-running-tray__stack-mark"
          harness={part.harness ?? agent.harness ?? chatHarness}
          tone={agentTone(agent.id)}
          size={ROW_ICON}
          fallback={part.icon}
          plain
        />
      ) : (
        <Icon name={part.icon} size={ROW_ICON} row />
      )}
      <Tick className="acpmux-running-tray__kind-text" text={kindText} steadyCounts />
    </span>
  );
}

/// A kind's mark in the `summary` header: a subagent kind its harness's logo, plain like every hat
/// mark (no session badge: Leo, 2026-11-27, "there was a really dumb looking symbol in the top left
/// of the composer hat"); its first subagent's tone still colors a fallback glyph. Any other kind
/// draws its own icon.
function KindMark({ part, chatHarness }: { part: TrayHeadPart; chatHarness: string | undefined }) {
  const lead = part.items[0];
  const agent = part.key.startsWith("agents") && lead?.kind === "agent" ? lead.agent : undefined;
  return agent ? (
    <AgentIdentity
      className="acpmux-running-tray__stack-mark"
      harness={part.harness ?? agent.harness ?? chatHarness}
      tone={agentTone(agent.id)}
      size={ROW_ICON}
      fallback={part.icon}
      plain
    />
  ) : (
    <Icon name={part.icon} size={ROW_ICON} row />
  );
}

type HeadMark = { key: string; harness?: string; tone?: number; icon: string };
const NO_MARKS: readonly HeadMark[] = [];
/// A lone item's deck: its header already names it, so pointing at its mark changes nothing.
const noPeek = () => {};
/// How many lines' marks the header stacks; the counts after them say the rest.
const STACK_MARKS = 4;

/// The marks the header stacks (the `stack` arm): the first lines' own glyphs, what runs first, then
/// what ended. Agents use their harness logos; commands share one terminal mark.
/// Computed when the lists change, never per tick.
function stackMarks(
  items: readonly TrayItem[],
  finished: readonly TrayItem[],
  chatHarness: string | undefined,
): readonly HeadMark[] {
  const marks: HeadMark[] = [];
  const hasCommands = items.some((item) => item.kind === "command") || finished.some((item) => item.kind === "command");
  const agentLimit = STACK_MARKS - (hasCommands ? 1 : 0);
  let agentsShown = 0;
  let commandsShown = false;
  for (const item of [...items, ...finished]) {
    if (marks.length === STACK_MARKS) break;
    if (item.kind === "command") {
      if (commandsShown) continue;
      commandsShown = true;
    } else {
      if (agentsShown === agentLimit) continue;
      agentsShown += 1;
    }
    marks.push(
      item.kind === "agent"
        ? {
            key: itemKey(item),
            harness: item.agent.harness ?? chatHarness,
            tone: agentTone(item.agent.id),
            icon: SUBAGENT_FALLBACK,
          }
        : item.kind === "command"
          ? { key: "commands", icon: "terminal" }
          : item.kind === "turn"
            ? { key: "turns", icon: SILENT_TURN_ICON }
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

const NO_ITEMS: readonly TrayItem[] = [];
const NO_ARRIVALS: ReadonlySet<string> = new Set();
/// A line leaving the open list: its last card, and its place among the lines drawn then.
type Leaving = { readonly card: TrayCard; readonly index: number };
const NO_LEAVING: ReadonlyMap<string, Leaving> = new Map();
/// A line as the open list draws it: its key, its card, and whether it is leaving.
type DrawnCard = { readonly key: string; readonly card: TrayCard; readonly leaving: boolean };
const NO_DRAWN: readonly DrawnCard[] = [];

/// The list's lines with the leaving ones back where they were drawn, so the lines around a leaving
/// one stay put while it folds away. A key in both (it came back) is drawn once, as itself.
function withLeaving(cards: readonly TrayCard[], leaving: ReadonlyMap<string, Leaving>): readonly DrawnCard[] {
  const out: DrawnCard[] = cards.map((card) => ({ key: itemKey(card.item), card, leaving: false }));
  if (leaving.size === 0) return out;
  const present = new Set(out.map((drawn) => drawn.key));
  const going = [...leaving].filter(([key]) => !present.has(key)).sort((a, b) => a[1].index - b[1].index);
  for (const [key, { card, index }] of going) out.splice(Math.min(index, out.length), 0, { key, card, leaving: true });
  return out;
}

/// Focus a navigation key moved here (focusRingShown), which holds the hat; a click's focus does not.
function focusVisible(event: FocusEvent<HTMLElement>): boolean {
  try {
    return focusRingShown(event.target as Element);
  } catch {
    return false;
  }
}

/// One line of the open list. A line that joins (`enters`) grows from 0 height, fading in, and a
/// line that leaves keeps its node, out of reach (`inert`), and folds to 0 height, fading out, both
/// on the shared fold (conversation/fold.ts `useFold`: the pane's move duration and ease-out), so the
/// lines around it move with it on the same clock, with no jump at either end (Leo, 2026-11-07: "the
/// things coming, they shouldn't just, like, pop in, burst in, like, appear instantly, and, like,
/// disappear instantly"; a fade in place, or a rise with the fold, lost in the gallery). When the fold ends (at once with no motion) a
/// leaving line calls `gone` and unmounts. A line that comes back mid-leave turns back from where it
/// is drawn. The fold's own animation is its only timer; it ends, or is cancelled when the row goes.
function TrayRow({
  rowKey,
  enters,
  leaving,
  entered,
  gone,
  finished,
  first,
  children,
}: {
  rowKey: string;
  enters: boolean;
  leaving: boolean;
  entered: (key: string) => void;
  gone: (key: string) => void;
  finished: boolean;
  first: boolean;
  children: ReactNode;
}) {
  // A joining line is first drawn shut, then opens before the frame paints.
  const [shown, setShown] = useState(!enters);
  const [arrived] = useState(enters);
  useLayoutEffect(() => {
    if (shown) return;
    setShown(true);
    entered(rowKey);
  }, [shown, entered, rowKey]);
  const fold = useFold(shown && !leaving, entranceMayRun);
  useLayoutEffect(() => {
    if (leaving && !fold.present) gone(rowKey);
  }, [leaving, fold.present, gone, rowKey]);
  return (
    <li
      data-finished={finished ? "" : undefined}
      data-first-finished={first || undefined}
      data-arrived={arrived || undefined}
      data-leaving={leaving || undefined}
      inert={leaving || undefined}
      aria-hidden={leaving || undefined}
    >
      {fold.present && (
        <div ref={fold.ref} className="acpmux-running-tray__row">
          {children}
        </div>
      )}
    </li>
  );
}
/// The most lines that rise in from one update; a bigger burst is simply there.
const ARRIVALS_PER_UPDATE = 3;
/// The shared gate on an entrance or a fold now: the page shows, its first frame back has passed, and
/// the host's motion is on (shared/pageReveal.ts).
const entranceMayRun = () => entranceAllowed();

/// How long a command has run, or ran: to its end once it ended. A running one ticks in its own leaf
/// (Elapsed.tsx), never in the line or the header that shows it.
function commandTime(command: BackgroundCommand): ReactNode {
  if (command.startedAt === undefined) return undefined;
  return <Elapsed since={command.startedAt} until={command.state === "running" ? undefined : command.endedAt} />;
}

/// How long a subagent has run, or ran (subagentGroupModel.ts `elapsed`): one waiting on background work
/// of its own has not ended, so its time keeps going. Ticking in its own leaf (Elapsed.tsx).
function agentTime(agent: Subagent): ReactNode {
  const live = ticking(agent);
  return (
    <Elapsed
      since={agent.startedAt}
      until={live ? undefined : agent.endedAt}
      ended={!live && agent.endedAt === undefined}
    />
  );
}

/// A started chat's line: its turn runs, it waits on the person, its turn failed, or it is done.
const SESSION_STATUS: Record<StartedSession["state"], SubagentStatus> = {
  running: "running",
  waiting: "waiting",
  failed: "failed",
  idle: "done",
};
