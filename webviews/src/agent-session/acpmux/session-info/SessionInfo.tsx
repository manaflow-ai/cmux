// Session Info: the right-hand panel of an agent chat, Chief included, opened by the header's
// top-right toggle (Claude Code desktop calls its own the session rail, ChatGPT its pinned
// summary). Leo, 2026-10-20: take the facts Claude Code's panel shows and ChatGPT's subagents row.
// Top to bottom, in three blocks with no box around a section (`RAIL_LAYOUT`):
//
// - Where it runs: the Environment's rows, the machine, the folder, the repository, the branch or
//   worktree (EnvironmentSection); then Context, how much of the context window the chat used, with a
//   bar, open the token counts; then Connectors, the MCP servers its harness loaded, with how many
//   need reconnecting, each failed one with a Reconnect where acpmux reconnects it (ConnectorsSection).
//   Context and Connectors are one row each until opened.
// - What it made: Changes, the pull requests it opened, touched or named, in any repository
//   (ChangesSection); Outputs, the files and artifacts it produced (OutputsSection).
// - What it runs: Subagents, each running subagent and started chat on its own line, the ended ones
//   folded into one row: the harness's subagents and the chats its agent started, a Cloud VM's or
//   another machine's included (SubagentsSection); Background tasks, the dev servers it runs first
//   (ServersSection), then its other background commands, the ones only the transcript knows
//   included, and its wakeups (TasksSection).
//
// Open, it takes one of three places by the pane's width (sessionInfoStage; Leo, 2026-11-03: "not
// affecting layout at all -> gradually pushing into the chat layout -> overlay"). Wide, it floats under
// the header's toggle in the pane's right gutter, beside the transcript's centered column, so opening,
// closing or updating it moves nothing. Where that gutter cannot hold it, it pushes into the chat
// gradually: the page keeps only the room the gutter lacks (pushedRoom), so the transcript's column moves
// left, never narrower (pushKeepsColumn). Where a push would narrow the column, and so wrap its lines
// anew, it lies over the chat and stops above the composer, and in a short pane it is a popover instead.
// Settings > Agent Chat > Session Info: Push always pushes wherever its whole room keeps the column.
// It shows only over the chat, where its toggle is: while a view takes the pane in the chat's place
// (a turn's diff in place, the event Inspector) it steps aside and comes back when that view closes,
// and with the side panel open beside the chat it floats in the chat's gutter, never over the
// document (Leo, 2026-10-22: "WHY DOES IT STAY ON IN THESE RANDOM SITUATIONS WITHOUT BEING
// CLOSABLE!?"). Its left edge drags to resize it. Open, width and folds are each pane's own
// (Leo, 2026-10-25: "they should all be individual per pane"), kept under the chat's session
// (sessionInfoState.ts). Debug Settings `agent.sessionInfo` (on by default)
// turns it off, which brings back the summary card it replaces (summary/SummaryCard.tsx). It reads
// only acpmux's common snapshot and the App's header state, never one harness's own fields.
// While the pane shows a subagent's own view, it lists that subagent's things alone, under
// "Subagent · <name>" with a back button (subagentScope.ts, SubagentScopeHeader.tsx).
import {
  memo,
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type CSSProperties,
  type ReactNode,
} from "react";
import { flushSync } from "react-dom";
import { useSeeThroughBlur } from "../../../ui/glass/seeThroughBlur";
import "../../../ui/controls.css";
import { useChatCut } from "./chatCut";
import { chatGlass, chatUnderGlass } from "../chatUnderGlass";
import { usePresence, type Presence } from "../../../ui/presence";
import { useChatDisplay } from "../chatDisplay";
import { useCountedRender } from "../perfRender";
import { CHAT_LAYOUT_EVENT, chatColumnOf, useChatSizing, type ChatColumn } from "../chatWidth";
import { FIND_HIDE_EVENT, FIND_OPEN_EVENT } from "../conversation/chatFind";
import { PanelToggle } from "../header/PanelToggle";
import { useHeaderState, type HeaderPullRequest } from "../header/headerState";
import { useTabRow } from "../header/tabRow";
import { usePaneLanguage, useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { transcriptColumn, type AcpmuxRow, type AcpmuxSnapshot } from "../model";
import { COMPUTER_USE_PREVIEW_RESERVE, useComputerUsePreview } from "../computerUse/computerUsePreview";
import { compactingUsage, type UsageCacheLayout } from "../usageStats";
import { registerPicker } from "../pickerOpeners";
import { ContextSection } from "./ContextSection";
import { opensProcessTerminal } from "../processTerminal";
import { tooltipProps } from "../shortcuts";
import { subagentsIn } from "../subagents/subagentRows";
import { chatGallery } from "../summary/chatGallery";
import { GalleryDialog } from "../summary/GalleryDialog";
import { useScrollEdges } from "../summary/scrollEdges";
import { sessionSummary, type SessionSummary, type SummaryBackgroundTask } from "../summary/sessionSummary";
import { waitingSubagents } from "../summary/subagentStatusListModel";
import type { Artifact } from "../conversation/artifactPreview";
import type { StartedSession } from "../started/startedSessions";
import { ChangesSection, headerStatus, visibleChanges, type SessionInfoPullRequestStatus } from "./ChangesSection";
import { useChangesStatuses, useStableUrls, withHeader } from "./changesStatus";
import { ConnectorsSection } from "./ConnectorsSection";
import { summarizeConnectors } from "./connectorState";
import { useIMessage, type IMessageView } from "./imessage";
import { EnvironmentSection, type AccessGrant, type ProjectRowLook } from "./EnvironmentSection";
import { SessionInfoSectionList, type SessionInfoCompactLook } from "./SessionInfoGroup";
import { sectionOrder, tuckedSections } from "./sectionOrder";
import { SessionInfoSection } from "./SessionInfoSection";
import { SourcesSection } from "./SourcesSection";
import { SUBAGENT_HEADER, SubagentBanner, SubagentTitle } from "./SubagentScopeHeader";
import {
  subagentBackLabel,
  subagentProcesses,
  subagentSummary,
  withChatEnds,
  type SubagentScope,
} from "./subagentScope";
import {
  bindSessionInfoPane,
  claimSessionInfoIMessageReveal,
  SESSION_INFO_WIDTH,
  sessionInfoPaneKey,
  setSessionInfoMore,
  setSessionInfoOpen,
  setSessionInfoSection,
  setSessionInfoSourcesAll,
  setSessionInfoWidth,
  useSessionInfoOpen,
  useSessionInfoState,
  type SessionInfoSectionId,
  type SessionInfoSections,
} from "./sessionInfoState";
import { OutputsSection, outputArtifacts, outputLinks, type OutputArtifact } from "./OutputsSection";
import { sessionInfoLists, type SessionInfoProcess, type ProcessRegistry } from "./processes";
import { ServersSection } from "./ServersSection";
import { SubagentLimitStepper } from "./SubagentLimitStepper";
import { SubagentCountsMeta, SubagentsSection } from "./SubagentsSection";
import { AlsoHereSection, useAlsoHere } from "./AlsoHereSection";
import { sessionStatus } from "./ChildSessionRows";
import { useChangeCounts, type ReadChanges } from "./changeCounts";
import { useStepAside } from "./stepAside";
import { chatOutputs } from "./chatOutputs";
import { tryChipHost } from "../chips/host";
import { useMissingPaths } from "../chips/linkStore";
import { TasksSection } from "./TasksSection";
import { currentPlan, planDone, ProgressSection, type SessionInfoPlan } from "./ProgressSection";
import { attributeCommands } from "../summary/workflowView";
import { WorkflowTasks, type WorkflowAgentRowVariant } from "./WorkflowTasks";
import { UsageSection, usageMeta, type UsageOwnRowLayout } from "./UsageSection";
import { AppPanelSection, useAppPanelSections } from "../../../apps/scene/panels";
import type { AcpmuxSessionEntry } from "../sessionList";
import type { WorkflowAgent, WorkflowSummary } from "../summary/workflow";
import type { Subagent } from "../subagents/subagentFold";
import { subagentProgress } from "../subagents/subagentProgress";
import { useUnderSessionInfo } from "./underSessionInfo";
import { useNativeSessionInfoHost } from "./native/host";
import { useSameValue } from "./sameValue";
import { chatPlace, type ChatPlace } from "../chatMachine";
import { usageEntries, type UsageEntry } from "./usageEntries";
import { samePanelProps } from "./samePanelProps";
import type { AlsoHere } from "./alsoHere";
import { NativeSessionInfo } from "./native/NativeSessionInfo";
import "./sessionInfo.css";

type Summary = NonNullable<AcpmuxSnapshot["summary"]>;
export type SessionInfoPlacement = "push" | "overlay";

/// The narrowest chat Session Info pushes aside: a pushed panel narrows to keep it, down to the
/// panel's own narrowest width.
export const PUSH_MIN_CHAT = 440;
/// The room the panel keeps from the pane's right edge, floating or pushing, and from the
/// transcript's column when it floats (sessionInfo.css --acpmux-session-info-inset).
export const FLOAT_MARGIN = 8;
/// How long after an output click a narrowing counts as that diff's split.
const SPLIT_SETTLE_MS = 2000;
/// A chat with no folders beside its own (one shared empty list, so the section's props keep their identity).
const NO_FOLDERS: readonly string[] = [];

/// Whether Settings Push always is on: Session Info then always takes a column.
export const pushes = (placement: SessionInfoPlacement) => placement === "push";

/// The narrowest a pushed panel gets in a tight pane, below the drag's narrowest
/// (SESSION_INFO_WIDTH.min), and still as wide as the live preview card under it (computerUsePreview.css,
/// 180px). Pushed at 260px in a 370px agent pane, the chat kept about 100px, with its "Not sent" line,
/// Retry and composer under the panel (cmuxterm-hq#6137; Leo, 2026-11-02: "THE FUCKING SESSION INFO NOT
/// FUCKING PUSH THE LAYOUT LEFT").
export const PUSH_PANEL_MIN = 200;

/// A pushed panel's width: its own, narrowed so the chat keeps PUSH_MIN_CHAT beside it and its
/// right margin, down to PUSH_PANEL_MIN, and never past the pane less its margins. The chat takes the
/// rest of the pane beside it: the two never overlap.
export const pushedWidth = (paneWidth: number, width: number) =>
  paneWidth <= 0
    ? width
    : Math.max(
        0,
        Math.min(
          width,
          Math.max(PUSH_PANEL_MIN, paneWidth - PUSH_MIN_CHAT - FLOAT_MARGIN),
          paneWidth - 2 * FLOAT_MARGIN,
        ),
      );

/// Whether the pane holds a readable chat (PUSH_MIN_CHAT) beside the panel at its narrowest: the
/// boundary between pushing and lying over the chat (sessionInfoStage). Below it, Session Info does not
/// open from a saved open state alone (a new chat, a relaunch, a pane narrowed under it): over a narrow
/// chat it waits for the person's toggle. Unmeasured (0) counts as room.
export const sessionInfoFits = (paneWidth: number) =>
  paneWidth <= 0 || paneWidth - PUSH_PANEL_MIN - FLOAT_MARGIN >= PUSH_MIN_CHAT;

/// A handoff review's form (handoff/styles.css: 760px, 18px from each edge) takes the transcript's
/// place and is wider than the column.
export const HANDOFF_FORM_WIDTH = 760;
/// The form's clearance from each pane edge (handoff/styles.css `min(760px, calc(100% - 36px))`).
export const HANDOFF_FORM_EDGE = 18;
/// The floating panel's right gutter: the transcript's (model.ts transcriptColumn), or with `wide` the
/// handoff review form's.
const gutterOf = (paneWidth: number, column?: ChatColumn, wide = false) => {
  const columnInset = transcriptColumn(paneWidth, column).inset;
  return wide
    ? Math.min(columnInset, (paneWidth - Math.min(HANDOFF_FORM_WIDTH, paneWidth - 2 * HANDOFF_FORM_EDGE)) / 2)
    : columnInset;
};

/// Whether the floating panel would lie over the chat's column: the right gutter cannot hold it and
/// its margins. By default it then pushes the chat (sessionInfoPushes); where it still floats (a short
/// pane's popover, a handoff review's form), the card, full length otherwise, stops above the
/// composer's stack so it never covers the composer.
export const sessionInfoOverChat = (paneWidth: number, width: number, column?: ChatColumn, wide = false) => {
  if (paneWidth <= 0 || width <= 0) return false;
  return width + 2 * FLOAT_MARGIN > gutterOf(paneWidth, column, wide);
};

/// Below this pane height, a panel that lies over the chat is a popover: it hides when a click lands
/// anywhere else, and while it shows it covers the composer instead of stopping above it. A taller pane
/// keeps the card above the composer, its foot following the composer's top with an animation
/// (sessionInfo.css), never a jump (Leo, 2026-10-31: "THE FACT THIS SHIT FUCKING EXPANDS WHEN THE
/// COMPOSER GROWS OR SHRINKS IS... ok i guess but i feel like should have an animation... sometimes
/// the claude code/chatgpt desktop just straight up make it a popover that hides when you click away
/// when the viewport is indeed too small"). It reads the pane's height alone, never the composer's, so
/// typing a long draft never switches the panel between the two.
export const POPOVER_BELOW_HEIGHT = 520;

/// Whether the floating panel is a popover (POPOVER_BELOW_HEIGHT): it lies over the chat in a short
/// pane. A popover shows only when the person opens it (SessionInfoPresence `asked`), never from a
/// saved open state alone.
export const sessionInfoPopover = (paneHeight: number, overChat: boolean) =>
  overChat && paneHeight > 0 && paneHeight < POPOVER_BELOW_HEIGHT;

/// Where Session Info goes, by the pane's width (Leo, 2026-11-03: "but you should still be able to have
/// it be an overlay... we previously had all that behaviour logic going from not affecting layout at
/// all -> gradually pushing into the chat layout -> overlay"):
/// - `float`: the right gutter holds it and its margins; the chat does not move (Leo, 2026-10-31: "why
///   is the session info thing still pushing my layout when it doesnt need to???").
/// - `push`: the gutter cannot hold it, and pushing keeps the transcript's column at the width it has
///   without the panel (pushKeepsColumn): it pushes into the chat by only what the gutter lacks
///   (pushedRoom), so the column moves left and its text never wraps anew (Leo, 2026-11-03: "the agent
///   chat's horizontal width shouldn't be shifted its position sure but it itself and its text
///   shouldn't be affected by the session info if it would need to be then session info should be an
///   overlay").
/// - `overlay`: pushing would narrow the column: it lies over the chat and stops above the composer (a
///   popover in a short pane, POPOVER_BELOW_HEIGHT). A short pane and a handoff review's wider form never
///   push either.
/// With Settings Push always, `push` wherever its whole room keeps the column's width, else `overlay`
/// too. `overflow` is how far the chat's drawn content reaches past the column the model expects
/// (chatContentOverflow): a panel that would lie over any row or the composer does not float, whatever
/// the gutter's width says.
export type SessionInfoStage = "float" | "push" | "overlay";
export const sessionInfoStage = (
  placement: SessionInfoPlacement,
  pane: { width: number; height: number },
  width: number,
  column?: ChatColumn,
  wide = false,
  overflow = 0,
): SessionInfoStage => {
  if (!pushes(placement)) {
    // Wherever the column fits beside the whole panel, the chat moves left and centers in what the panel
    // leaves, a wide pane too, as Codex's does (Lucas, 2026-11-06: "we need to make sure that the chat is
    // centered when the session info is open"): floating in a wide gutter left it 348px from the pane's
    // left and 20px from the panel at 1500px. A handoff review's wide form and a short pane's popover
    // keep their own places.
    const all = pushedWidth(pane.width, width) + FLOAT_MARGIN;
    if (!wide && pane.width > 0 && !sessionInfoPopover(pane.height, true) && pushKeepsColumn(pane.width, all, column))
      return "push";
    if (!sessionInfoOverChat(pane.width, width + (wide ? 0 : Math.max(0, overflow)), column, wide)) return "float";
    if (wide || sessionInfoPopover(pane.height, true) || !sessionInfoFits(pane.width)) return "overlay";
  }
  const room = pushedRoom(pane.width, pushedWidth(pane.width, width), column, overflow, pushes(placement));
  return pushKeepsColumn(pane.width, room, column) ? "push" : "overlay";
};

/// The shell's pin on the transcript's column while Session Info pushes (sessionInfo.css).
const SESSION_INFO_COLUMN = "--acpmux-session-info-column";
/// How far the column moves left while it pushes (sessionInfo.css --acpmux-session-info-shift).
const SESSION_INFO_ROOM = "--acpmux-session-info-room";
/// The animated column shift itself (sessionInfo.css, a registered custom property).
const SHIFT = "--acpmux-session-info-shift";
/// Whether the chat's column is sliding now (its shift's transition runs on the shell's main).
const columnSliding = (shell: HTMLElement) => {
  const main = shell.querySelector<HTMLElement>(":scope > .acpmux-main");
  // Reading the animations brings the page's styles up to date first, so a slide set a moment ago runs.
  if (!main || typeof main.getAnimations !== "function") return false;
  return main.getAnimations().some((animation) => (animation as CSSTransition).transitionProperty === SHIFT);
};

/// The shell's room Find in Chat's bar keeps from the chat's right edge (conversation.css .acpmux-find__bar).
export const SESSION_INFO_CLEAR = "--acpmux-session-info-clear";

/// How far the panel's left edge lies inside the chat's right edge, in every stage: the panel and its
/// margin, less the room a push takes from the chat beside it (`room`, pushedRoom; 0 floating or over the
/// chat). Find in Chat's bar keeps this clear, so it sits in the chat's column left of the panel and
/// never under it (Leo, 2026-11-03: "oh no the command f overlaps with the session info..").
export const sessionInfoClear = (panelWidth: number, room: number) =>
  Math.max(0, Math.round(panelWidth + FLOAT_MARGIN - room));

/// Find in Chat's bar at its narrowest (ui/findPill.css: its padding, icon, a 40px field, the count,
/// the separator and three buttons), and its inset from the column's edges (--find-pill-inset).
export const FIND_BAR_MIN = 230;
export const FIND_BAR_INSET = 10;

/// Whether a chat `chatWidth` wide has no room for Find in Chat's bar at its narrowest beside the panel
/// (`clear`, sessionInfoClear): Session Info then steps aside when Find opens (FIND_OPEN_EVENT), as it
/// does for a diff in place, instead of covering the bar; its toggle brings it back. Unmeasured (0) counts as room.
export const findBarCramped = (chatWidth: number, clear: number) =>
  chatWidth > 0 && chatWidth - clear - 2 * FIND_BAR_INSET < FIND_BAR_MIN;

/// Whether a push that takes `room` from the chat's right end keeps the transcript's column at the
/// width it has in the whole pane (model.ts transcriptColumn): only the gutters shrink, so the column
/// moves left and no line of the chat wraps anew. While it pushes, the page pins the column to that
/// width (sessionInfo.css --acpmux-session-info-column), so no frame of the slide narrows it either.
// While it pushes, the page pins the column to its whole-pane width and centers it, unrounded, in the
// chat beside the panel (sessionInfo.css): so a push keeps the column whenever that width and the two
// minimum page edges fit in the chat. The column's own width scales with the pane between its 720px
// floor and 800px cap, and the old exact-width check refused every push there, so the panel lay over
// the prompts instead (Lucas, 2026-11-06: "we should also shift the chat to the left so that the
// session summary doesnt overlap with prompts", as Codex's panel shifts its chat).
export const pushKeepsColumn = (paneWidth: number, room: number, column?: ChatColumn) =>
  paneWidth <= 0 ||
  room <= 0 ||
  (room < paneWidth &&
    paneWidth - room >= transcriptColumn(paneWidth, column).width + 2 * transcriptColumn(0, column).inset);

/// Where the pinned column (its whole-pane width, `pinned`) ends in a chat `chatWidth` wide: centered,
/// unrounded, never nearer the chat's sides than the page edge (sessionInfo.css).
const pinnedColumnEnd = (chatWidth: number, pinned: number, edge: number) =>
  chatWidth - Math.max(edge, (chatWidth - pinned) / 2);

/// Whether Session Info pushes the chat aside (sessionInfoStage `push`).
export const sessionInfoPushes = (
  placement: SessionInfoPlacement,
  pane: { width: number; height: number },
  width: number,
  column?: ChatColumn,
  wide = false,
  overflow = 0,
) => sessionInfoStage(placement, pane, width, column, wide, overflow) === "push";

/// Where the transcript's column ends in a chat `chatWidth` wide (model.ts transcriptColumn): it never
/// moves right as the chat widens.
const columnEnd = (chatWidth: number, column?: ChatColumn) => chatWidth - transcriptColumn(chatWidth, column).inset;

/// A room stepped in 8px increments while the column needs only part of the panel: the column's inset is
/// on the 4 grid (model.ts transcriptColumn, design/grid.md 5.5), so the centered column keeps its width.
/// The room a pushed panel `panel` wide (pushedWidth) takes from the chat's right end: by default only
/// what the gutter lacks, so the chat narrows gradually from the pane width where the gutter stops
/// holding the panel (0 there) to the panel and its margin (Leo, 2026-11-03: "gradually pushing into the
/// chat layout"). It is the least room that keeps the transcript's column, and `overflow` past it, a
/// margin clear of the panel. With `full` (Settings Push always), the panel and its margin.
export const pushedRoom = (paneWidth: number, panel: number, column?: ChatColumn, overflow = 0, full = false) => {
  const all = panel + FLOAT_MARGIN;
  if (paneWidth <= 0) return all;
  // Panel widths are user-controlled and may be any pixel value. Keep the panel's own 8px inset exact
  // instead of rounding the whole room up: an odd drag width must not leave a gap (#33865).
  if (full) return all;
  // Pushed, the column keeps its whole-pane width, centered in the chat (pinnedColumnEnd).
  const pinned = transcriptColumn(paneWidth, column).width;
  const edge = transcriptColumn(0, column).inset;
  // Wherever the pinned column fits beside the whole panel, it takes the whole room: the chat is
  // centered in what the panel leaves, as Codex's is (Lucas, 2026-11-06: "we need to make sure that
  // the chat is centered when the session info is open, currently its a bit too shifted to the right").
  if (paneWidth - all >= pinned + 2 * edge) return all;
  const end = paneWidth - panel - 2 * FLOAT_MARGIN - Math.max(0, overflow);
  if (columnEnd(paneWidth, column) <= end) return 0;
  if (paneWidth - all <= 0 || pinnedColumnEnd(paneWidth - all, pinned, edge) > end) return all;
  // Else the least room, in steps of 8, whose column still ends by `end`. At most about 70 steps, run once
  // per layout of the panel.
  let room = 8;
  while (room < all && pinnedColumnEnd(paneWidth - room, pinned, edge) > end) room += 8;
  // Once the chat would end under the panel itself (its page edge under the card), the whole room: the
  // chat's right edge, its scrollbar with it, is then the panel's left margin, as Push always draws it.
  return room >= panel ? all : room;
};
/// The chat's content Session Info must never float over: the transcript's rows and the composer.
const CHAT_CONTENT = ".acpmux-main :is(.acpmux-row, .acpmux-composer-box)";

/// How far the chat's drawn content reaches past the right end of the column the model expects for a
/// chat `chatWidth` wide (the chat's width less the transcript's gutter, from the shell's left edge); 0
/// when it stays inside. Read while the panel floats (the chat has the pane's full width) or pushes by
/// less than its full room (pushedRoom), with the chat's width now; the caller keeps the largest reading
/// until the panel closes, so a push it causes never undoes it.
/// While pushed (`pinnedFrom`, the pane's width), the column is the pinned one, its whole-pane width
/// centered in the chat (pinnedColumnEnd): measured against the chat's own narrower column, every row
/// read as reaching past it, and the push took more room than it needed.
export function chatContentOverflow(
  shell: HTMLElement,
  chatWidth: number,
  column?: ChatColumn,
  pinnedFrom?: number,
): number {
  if (chatWidth <= 0) return 0;
  const left = shell.getBoundingClientRect().left;
  const end =
    pinnedFrom && pinnedFrom > chatWidth
      ? pinnedColumnEnd(chatWidth, transcriptColumn(pinnedFrom, column).width, transcriptColumn(0, column).inset)
      : columnEnd(chatWidth, column);
  let reach = 0;
  for (const element of shell.querySelectorAll<HTMLElement>(CHAT_CONTENT)) {
    const { right, width } = element.getBoundingClientRect();
    if (width > 0) reach = Math.max(reach, right - left);
  }
  // Under half a pixel is the shell's sub-pixel offset, not content under the panel.
  return Math.max(0, Math.floor(reach - end + 0.5));
}

/// Whether Session Info shows: on (Debug Settings `agent.sessionInfo`), open (the viewer's, in every
/// chat tab), not stepped aside for a diff split, and only over the chat: never while a view takes
/// the pane in its place (`covered`: a turn's diff in place hides the header, and the toggle with it).
export const sessionInfoShown = ({
  on,
  open,
  suppressed = false,
  covered = false,
}: {
  on: boolean;
  open: boolean;
  suppressed?: boolean;
  covered?: boolean;
}) => on && open && !suppressed && !covered;

/// The side panel beside the chat (conversation/ArtifactPanel.tsx), a child of the pane's shell, or
/// the Background tasks column (backgroundTasks/BackgroundTasksPanel.tsx), which docks under it or
/// stands in its place at the same width.
const SIDE_PANEL = ":scope > .acpmux-artifact, :scope > .acpmux-bg";

/// Session Info starts right below the header: the pane's tab row when the header is in it.
export function sessionInfoTopOffset(tabRowHeight: number): string {
  return tabRowHeight > 0 ? `${tabRowHeight}px` : "var(--acpmux-header-height, 28px)";
}

/// AppKit's top is in page CSS pixels, below the same header or shared tab row as the web panel.
function nativeTop(shell: HTMLElement | null | undefined, tabRowHeight: number): number {
  const shellTop = Math.max(0, shell?.getBoundingClientRect().top ?? 0);
  if (tabRowHeight > 0) return shellTop + tabRowHeight;
  const header = shell ? Number.parseFloat(getComputedStyle(shell).getPropertyValue("--acpmux-header-height")) : NaN;
  return shellTop + (Number.isFinite(header) ? header : 28);
}

/// The composer's stack height (`.acpmux-dock` in `shell`) while `on`: from the top of its highest
/// child to the shell's foot. A new chat's dock is `display: contents` (bottomStack.css), so its own
/// box is empty and only its children have one. One ResizeObserver on the dock and its children (a
/// MutationObserver re-observes when its children change), both disconnected when `on` goes false or
/// the shell changes.
/// A change the observers see is drawn in the frame the stack changed (flushSync, as VirtualTranscript
/// follows the same stack): a scheduled render drew the panel's old foot over the grown stack for a
/// frame or more (the running tray coming in under an expanded Session Info).
function useDockHeight(shell: HTMLElement | null | undefined, on: boolean): number {
  const [height, setHeight] = useState(0);
  useLayoutEffect(() => {
    const dock = on ? shell?.querySelector<HTMLElement>(".acpmux-dock") : null;
    if (!shell || !dock) return;
    const measure = () => {
      let top = Infinity;
      for (const part of [dock, ...dock.children]) {
        const box = part.getBoundingClientRect();
        if (box.height > 0) top = Math.min(top, box.top);
      }
      return top === Infinity ? 0 : Math.max(0, Math.round(shell.getBoundingClientRect().bottom - top));
    };
    let last = measure();
    const read = () => {
      const next = measure();
      if (next === last) return;
      last = next;
      flushSync(() => setHeight(next));
    };
    const resize = new ResizeObserver(read);
    const observe = () => {
      resize.disconnect();
      resize.observe(dock);
      for (const child of dock.children) resize.observe(child);
    };
    observe();
    setHeight(last);
    const children = new MutationObserver(() => {
      observe();
      read();
    });
    children.observe(dock, { childList: true });
    return () => {
      children.disconnect();
      resize.disconnect();
    };
  }, [shell, on]);
  return height;
}

/// The chat's room in the pane: the pane's width less the side panel's beside the chat, and that
/// panel's width, which the floating Session Info keeps clear of.
export type PaneRoom = { width: number; side: number; height: number };
const UNMEASURED: PaneRoom = { width: 0, side: 0, height: 0 };
export function paneRoom(shell: HTMLElement): PaneRoom {
  const side = shell.querySelector<HTMLElement>(SIDE_PANEL)?.offsetWidth ?? 0;
  return { width: Math.max(0, shell.clientWidth - side), side, height: shell.clientHeight };
}

/// The chat's room, followed as the pane resizes and as the side panel opens, closes or resizes
/// (`beside` changes with it); width 0 before it is measured. A resize draws in the frame that has
/// the new width: the observer runs after that frame's layout and before its paint, and `flushSync`
/// renders the panel's place there (state set plainly drew a frame or more later, the panel floating
/// over the narrowed transcript before the chat jumped aside: "WHY DOES IT FLICKER").
function usePaneRoom(shell: HTMLElement | null | undefined, live: boolean, beside: unknown): PaneRoom {
  const [room, setRoom] = useState<PaneRoom>(UNMEASURED);
  useLayoutEffect(() => {
    if (!shell || !live) return;
    const measure = () => {
      const next = paneRoom(shell);
      setRoom((current) =>
        current.width === next.width && current.side === next.side && current.height === next.height ? current : next,
      );
    };
    measure();
    if (typeof ResizeObserver !== "function") return;
    const observer = new ResizeObserver(() => flushSync(measure));
    observer.observe(shell);
    const side = shell.querySelector<HTMLElement>(SIDE_PANEL);
    if (side) observer.observe(side);
    return () => observer.disconnect();
  }, [shell, live, beside]);
  return room;
}

/// Whether the chat's pane has no room for Session Info beside a readable chat (sessionInfoFits),
/// followed as the pane resizes and as the side panel opens or closes (`beside`) while `live`;
/// undefined until measured. One ResizeObserver on the shell, set state only when the answer flips.
function useNarrowPane(shell: HTMLElement | null | undefined, live: boolean, beside: unknown): boolean | undefined {
  const [narrow, setNarrow] = useState<boolean>();
  useLayoutEffect(() => {
    if (!shell || !live) return;
    const measure = () => {
      const width = paneRoom(shell).width;
      if (width > 0) setNarrow(!sessionInfoFits(width));
    };
    measure();
    if (typeof ResizeObserver !== "function") return;
    const observer = new ResizeObserver(measure);
    observer.observe(shell);
    return () => observer.disconnect();
  }, [shell, live, beside]);
  return narrow;
}

/// How long a revealed section stays lit.
const REVEAL_LIT_MS = 1200;

/// The header's toggle and Session Info for the chat's pane. `on` is Debug Settings
/// `agent.sessionInfo`: off, there is neither, and the App shows its summary card instead.
export function useSessionInfo({
  snapshot,
  machineName,
  repository,
  cloudRepositoryAvailable,
  shell,
  grants,
  onOpenOutput,
  onOpenSourceFile,
  onOpenUrl,
  onOpenImage,
  readPromptImage,
  onOpenDocument,
  processes: registry,
  onStopProcess,
  subagents,
  sessions,
  onSetRunningLimit,
  workflows,
  onOpenFolder,
  readChanges,
  onOpenChanges,
  onSaveEnvironment,
  onShowCall,
  subagent,
  split = false,
  covered = false,
  onUncover,
  onBeforeOpen,
  beside,
  wide = false,
  onReconnectMcp,
  remoteControl,
  onCompact,
  onViewPrompt,
  onOpenChat,
  onShowUsage,
  onRender,
}: {
  snapshot: AcpmuxSnapshot;
  /// A view has the pane in the chat's place (App.tsx: a turn's diff in place, the event Inspector):
  /// the panel steps aside, its open state kept, and is back when that view closes.
  covered?: boolean;
  /// Closes that view: opening Session Info (its toggle, the palette, a running line's count)
  /// brings the chat back first.
  onUncover?: () => void;
  /// Clears a competing full-height view before any Session Info entry point opens it.
  onBeforeOpen?: () => void;
  /// The side panel beside the chat, changing as it opens or closes (App.tsx `artifact.opened`):
  /// the panel measures the chat's room without it.
  beside?: unknown;
  /// What the chat shows under its header is a handoff review's form, wider than the transcript's
  /// column (App.tsx): whether the panel lies over the chat is measured against the form. It never pushes.
  wide?: boolean;
  /// This Mac's name from the handshake, for a local chat.
  machineName?: string;
  /// The chat folder's GitHub repository (`git.githubRepository`), `owner/name`.
  repository?: string;
  /// Native says whether this pane has an authenticated Cloud repository route.
  cloudRepositoryAvailable?: boolean;
  /// The pane's shell: Session Info measures it to float or push.
  shell?: HTMLElement | null;
  /// What the chat was granted (folder trust, a chat-wide allowance), each revocable in Environment.
  grants?: readonly AccessGrant[];
  /// Opens a file's diff (App.tsx openOutput: beside the chat, else in place).
  onOpenOutput?: (path: string) => void;
  onOpenSourceFile?: (path: string) => unknown;
  /// Opens a web address in the browser beside the chat (a server's port, a pull request).
  onOpenUrl?: (url: string) => void;
  onOpenImage?: (src: string, alt: string, path?: string) => void;
  /// A pasted image's bytes by its id, for its Sources row (direct.ts `promptImage`).
  readPromptImage?: (id: string) => Promise<string | undefined>;
  /// Opens a document the chat produced in the side panel beside the chat (App.tsx openArtifact).
  onOpenDocument?: (artifact: Artifact) => void;
  /// acpmux's background-process registry for the chat: the App's one (App.tsx `processRegistry`),
  /// which the running line and the summary card read too, so it is listed once.
  processes?: ProcessRegistry;
  /// `_acpmux/process/kill`.
  onStopProcess?: (id: string) => Promise<unknown>;
  subagents?: {
    views: Record<string, AcpmuxRow[]> | undefined;
    /// The tool calls the chat's open asks are about (SubagentStatusList.tsx `pendingToolCalls`).
    asks: ReadonlySet<string>;
    onOpen: (id: string) => void;
  };
  /// The chats the chat's agent started (App.tsx `childSessions`), and how one opens.
  sessions?: { list: readonly StartedSession[]; onOpen: (sessionId: string) => void };
  /// `_acpmux/subsession/limits` (direct.ts setRunningLimit): chat `sessionId`'s running limit.
  onSetRunningLimit?: (sessionId: string, maxRunning: number | null, from?: number) => Promise<unknown>;
  /// The chat's Claude workflows (Labs, App.tsx `workflows`), in Background tasks (WorkflowTasks.tsx).
  workflows?: {
    list: readonly WorkflowSummary[];
    onStop?: (id: string) => Promise<unknown>;
    onOpenAgent?: (agent: WorkflowAgent) => void;
  };
  /// Opens one of the chat's folders in the Files tree beside the chat (a chat on this Mac).
  onOpenFolder?: (path: string) => void;
  /// Reads the chat folder's git changes for Environment's Changes row (changeCounts.ts), with
  /// `onOpenChanges` opening the chat folder's diff beside the chat.
  readChanges?: ReadChanges;
  onOpenChanges?: () => void;
  /// Saves the chat's machine and folder as an environment (`environment.save`).
  onSaveEnvironment?: () => Promise<unknown>;
  /// Shows the Bash call that started a background command in the transcript (App.tsx `showToolRow`).
  onShowCall?: (toolCallId: string) => boolean;
  /// The subagent whose own view the pane shows: Session Info lists its things, not the chat's.
  subagent?: SubagentScope;
  /// The pane was opened beside another chat (a subagent's pane, a chat its agent started): its
  /// Session Info is its own and starts closed (sessionInfoState.ts `sessionInfoPaneKey`).
  split?: boolean;
  /// Reconnects one of the chat's failed MCP servers by name (`_acpmux/mcp/reconnect`).
  onReconnectMcp?: (server: string) => Promise<unknown>;
  /// Environment's Remote Control switch (App.tsx, remoteControl.ts): absent, no row.
  remoteControl?: { on: boolean; set: (on: boolean) => void };
  /// Sends the chat's agent its `/compact` (Context's and Usage's Compact); unset where it cannot reach.
  onCompact?: () => void;
  /// Context's View Prompt: opens the Context screen (context/ContextScreen.tsx); unset for a chat
  /// whose prompt text acpmux does not hand this pane.
  onViewPrompt?: () => void;
  /// Opens any chat acpmux lists, this Mac's or a peer's (Usage's rows).
  onOpenChat?: (sessionId: string) => void;
  /// Asks acpmux for every listed chat's usage now (`_acpmux/sessions` `usage: true`), once each
  /// time the panel shows: what Usage lists is otherwise the last read's, or none at all.
  onShowUsage?: () => void;
  /// Test-only render probe for the transcript scroll isolation regression test.
  onRender?: () => void;
}): {
  on: boolean;
  /// The panel shows (on, open, not stepped aside): a card under it keeps no room of its own beside
  /// the chat (App.tsx, the computer use live preview).
  shown?: boolean;
  button?: ReactNode;
  panel?: ReactNode;
  // The native command palette shares the header's visibility and uncover behavior.
  toggle?: () => void;
  // Opens Session Info with `section` unfolded (the running line's counts: App.tsx).
  reveal?: (section: SessionInfoSectionId) => void;
} {
  const t = useT();
  const { sessionInfo: on, pullRequest, lit } = useHeaderState();
  // This pane's state is its chat's: a relaunched pane shows Session Info as it left it, and a
  // toggle in another pane never reaches it (sessionInfoState.ts).
  // The chat's state is read from its first frame (`useSessionInfoOpen(paneSession)`), before the bind,
  // and the panel is keyed by the chat, so a pane switched to another chat shows that chat's
  // Session Info at once instead of playing the last chat's panel out.
  const paneSession = sessionInfoPaneKey(snapshot.sessionId ?? snapshot.summary?.sessionId, split);
  useLayoutEffect(() => bindSessionInfoPane(paneSession), [paneSession]);
  // Open alone: the width and the folds are the panel's (SessionInfoPresence), so a drag step or a fold
  // does not draw the whole chat pane again.
  const open = useSessionInfoOpen(paneSession);
  // Closed for now (not remembered): an output's diff split left no room beside the chat.
  const [suppressed, setSuppressed] = useState(false);
  const suppress = useCallback(() => setSuppressed(true), []);
  // The person opened it in this pane (the toggle, a running line's count, the palette), not only a
  // saved state: a popover shows only then (SessionInfoPresence). Both are this chat's: a pane switched
  // to another chat starts unasked and unsuppressed, so that chat's saved open state never puts a
  // popover over it either.
  const [asked, setAsked] = useState(false);
  const [askedFor, setAskedFor] = useState(paneSession);
  if (askedFor !== paneSession) {
    setAskedFor(paneSession);
    setAsked(false);
    setSuppressed(false);
  }
  // Aside while what one of its rows opened shows (stepAside.ts): the folder, Changes, an output.
  const stepAside = useStepAside(lit, shell);
  const backFromAside = stepAside.cancel;
  // A subagent shown in this pane in place (no pane of its own opened): the panel follows it there.
  const scopeId = subagent?.agent.id;
  useEffect(() => backFromAside(), [scopeId, backFromAside]);
  // Lucas, 2026-11-06: "In a narrow layout: it becomes a popover and starts closed." (Every new chat
  // starts closed since Leo, 2026-11-07: sessionInfoState.ts.) A pane with no room for it beside a readable chat
  // (sessionInfoFits) holds it closed until the person opens it there (`asked`); opened, it is a
  // popover (SessionInfoPresence). One already showing as the pane narrows (a split opens beside it)
  // stays, as a popover; and once the pane has room again, the chat's own open choice shows.
  const narrow = useNarrowPane(shell, on, beside);
  const roomyShown = sessionInfoShown({ on, open, suppressed: suppressed || stepAside.aside, covered });
  const [narrowWas, setNarrowWas] = useState(narrow);
  if (narrowWas !== narrow) {
    setNarrowWas(narrow);
    // Narrowed while it showed: it stays (the first measure is a start, not a narrowing).
    if (narrow && narrowWas === false && roomyShown) setAsked(true);
    // Room again: a popover's click-away or a cramped moment no longer holds it.
    if (!narrow && narrowWas) setSuppressed(false);
  }
  const shown = roomyShown && !(narrow && !asked);
  // The section a running line's count asked for, scrolled to once drawn.
  const [revealed, setRevealed] = useState<{ section: SessionInfoSectionId; at: number }>();
  const clearRevealed = useCallback(() => setRevealed(undefined), []);
  const openedOutputAt = useRef(0);
  const stableOnOpenOutput = useStableCallback(onOpenOutput);
  const stableOnOpenSourceFile = useStableCallback(onOpenSourceFile);
  const stableOnOpenUrl = useStableCallback(onOpenUrl);
  const stableOnOpenImage = useStableCallback(onOpenImage);
  const stableReadPromptImage = useStableCallback(readPromptImage);
  const stableOnOpenDocument = useStableCallback(onOpenDocument);
  const stableOnOpenFolder = useStableCallback(onOpenFolder);
  const stableOnOpenChanges = useStableCallback(onOpenChanges);
  const stableOnSaveEnvironment = useStableCallback(onSaveEnvironment);
  const stableOnReconnectMcp = useStableCallback(onReconnectMcp);
  const stableOnCompact = useStableCallback(onCompact);
  const stableOnViewPrompt = useStableCallback(onViewPrompt);
  const stableOnOpenChat = useStableCallback(onOpenChat);
  const stableOnShowUsage = useStableCallback(onShowUsage);
  const stableOnShowCall = useStableCallback(onShowCall);
  const stableOnStopProcess = useStableCallback(onStopProcess);
  const openOutput = useMemo(
    () =>
      stableOnOpenOutput
        ? (path: string) => {
            openedOutputAt.current = Date.now();
            stableOnOpenOutput(path);
          }
        : undefined,
    [stableOnOpenOutput],
  );
  const label = t("sessionInfo.title");
  // Opening it while a view covers the chat closes that view first. The palette's opener outlives a
  // render, so it reads the latest from a ref.
  const bringBack = covered ? onUncover : undefined;
  const uncover = useRef(bringBack);
  useLayoutEffect(() => {
    uncover.current = bringBack;
  }, [bringBack]);
  useEffect(() => {
    if (!on) return;
    return registerPicker(label, () => {
      onBeforeOpen?.();
      uncover.current?.();
      setSuppressed(false);
      backFromAside();
      setAsked(true);
      setSessionInfoOpen(true);
    });
  }, [on, label, onBeforeOpen, backFromAside]);
  // Esc closes it while the keyboard is in it or on its toggle (not in a text field there), before a
  // popup in the page takes it (they listen on the window, after the document). Anywhere else Esc
  // keeps its own meaning: with nothing focused and a turn running it is the composer's double press
  // that stops the turn (escapeStop.ts), which an Esc claimed here never reaches. An open popover,
  // menu or dialog takes Esc first (as WidgetEditing.tsx): they listen on the document too, but after this.
  useEffect(() => {
    if (!shown) return;
    const escape = (event: KeyboardEvent) => {
      if (event.key !== "Escape" || event.defaultPrevented || event.isComposing) return;
      const focus = document.activeElement;
      if (!(focus instanceof HTMLElement) || !focus.closest(`aside.acpmux-session-info, ${SESSION_INFO_TOGGLE}`))
        return;
      if (focus.closest("input, textarea, select, [contenteditable]:not([contenteditable=false])")) return;
      if (
        document.querySelector(
          'dialog[open], [role="dialog"], [role="alertdialog"], [role="menu"], [role="listbox"], .ui-popup',
        )
      )
        return;
      event.preventDefault();
      closeSessionInfo();
    };
    document.addEventListener("keydown", escape);
    return () => document.removeEventListener("keydown", escape);
  }, [shown]);
  if (!on) return { on: false };
  const toggle = () => {
    if (shown) setSessionInfoOpen(false);
    else {
      onBeforeOpen?.();
      bringBack?.();
      setSuppressed(false);
      backFromAside();
      setAsked(true);
      setSessionInfoOpen(true);
    }
  };
  const reveal = (section: SessionInfoSectionId) => {
    onBeforeOpen?.();
    bringBack?.();
    setSuppressed(false);
    backFromAside();
    setAsked(true);
    setSessionInfoSection(section, true);
    setSessionInfoOpen(true);
    setRevealed({ section, at: Date.now() });
  };
  return {
    on: true,
    shown,
    toggle,
    reveal,
    button: <PanelToggle className="acpmux-session-info-toggle" label={label} shown={shown} onToggle={toggle} />,
    panel: (
      <SessionInfoPresence
        key={paneSession ?? ""}
        chat={paneSession}
        shown={shown}
        snapshot={snapshot}
        pullRequest={pullRequest}
        machineName={machineName}
        repository={repository}
        cloudRepositoryAvailable={cloudRepositoryAvailable}
        shell={shell}
        grants={grants}
        beside={beside}
        wide={wide}
        openedOutputAt={openedOutputAt}
        asked={asked}
        onSuppress={suppress}
        onStepAside={stepAside.step}
        onStepBack={backFromAside}
        registry={registry}
        subagents={subagents}
        sessions={sessions}
        onSetRunningLimit={onSetRunningLimit}
        workflows={workflows}
        revealed={revealed}
        onRevealed={clearRevealed}
        onStopProcess={stableOnStopProcess}
        onOpenSourceFile={subagent?.agent.host ? undefined : stableOnOpenSourceFile}
        onOpenOutput={openOutput}
        onOpenUrl={stableOnOpenUrl}
        onOpenImage={stableOnOpenImage}
        // A subagent's prompt images live in its own chat, which this reader does not reach.
        readPromptImage={subagent ? undefined : stableReadPromptImage}
        onOpenFolder={stableOnOpenFolder}
        readChanges={subagent ? undefined : readChanges}
        onOpenChanges={subagent ? undefined : stableOnOpenChanges}
        onSaveEnvironment={stableOnSaveEnvironment}
        onReconnectMcp={stableOnReconnectMcp}
        remoteControl={remoteControl}
        onCompact={stableOnCompact}
        onViewPrompt={stableOnViewPrompt}
        onOpenChat={stableOnOpenChat}
        onShowUsage={stableOnShowUsage}
        onRender={onRender}
        onOpenDocument={stableOnOpenDocument}
        onShowCall={stableOnShowCall}
        scope={subagent}
      />
    ),
  };
}

const SESSION_INFO_TOGGLE = "button.acpmux-session-info-toggle";
/// Keep event props stable while retaining the latest callback. The pane owns transcript scroll
/// state, so a fresh inline callback would defeat the SessionInfoPresence memo.
function useStableCallback<T extends (...args: never[]) => unknown>(callback: T | undefined): T | undefined {
  const current = useRef<T | undefined>(callback);
  current.current = callback;
  const enabled = callback !== undefined;
  return useMemo(
    () => (enabled ? (((...args: Parameters<T>) => current.current?.(...args)) as T) : undefined),
    [enabled],
  );
}

/// What a press may land on without hiding the popover: a menu, popup or dialog the panel opened,
/// drawn outside it in a portal.
const DISMISS_KEEPERS =
  'dialog[open], [role="dialog"], [role="alertdialog"], [role="menu"], [role="listbox"], .ui-popup';

/// Closes Session Info from Esc and gives the keyboard to its header toggle, so focus is
/// not dropped on the page when the panel it was in leaves. Over a diff in place the header, and the
/// toggle with it, is hidden and cannot take focus: the page gets it, as before.
const closeSessionInfo = () => {
  document.querySelector<HTMLElement>(SESSION_INFO_TOGGLE)?.focus({ preventScroll: true });
  setSessionInfoOpen(false);
};

/// An Outputs file opens as the reply's path chip opens it (`link.openPath`); false when the host
/// refused it.
const openOutputFile = (path: string) => tryChipHost("link.openPath", { path });

/// Session Info while it is drawn: its presence, its width and folds, whether it floats or pushes,
/// and what it lists. Its own component, so its enter and exit phases, a drag step and a fold draw the panel
/// alone, not the chat pane that calls useSessionInfo (one Session Info open drew that pane five
/// times in a frame).
const SessionInfoPresence = memo(function SessionInfoPresence({
  chat,
  shown,
  snapshot,
  pullRequest,
  machineName,
  repository,
  cloudRepositoryAvailable,
  shell,
  grants,
  beside,
  wide,
  openedOutputAt,
  asked = false,
  onSuppress,
  onStepAside,
  onStepBack,
  registry,
  subagents,
  sessions,
  onSetRunningLimit,
  workflows,
  revealed,
  onRevealed,
  onStopProcess,
  onOpenOutput,
  onOpenSourceFile,
  onOpenUrl,
  onOpenImage,
  readPromptImage,
  onOpenFolder,
  readChanges,
  onOpenChanges,
  onSaveEnvironment,
  onReconnectMcp,
  remoteControl,
  onCompact,
  onViewPrompt,
  onOpenChat,
  onShowUsage,
  onRender,
  onOpenDocument,
  onShowCall,
  scope,
}: {
  /// The chat whose width and folds it draws (sessionInfoState.ts `useSessionInfoState`).
  chat: string | undefined;
  shown: boolean;
  snapshot: AcpmuxSnapshot;
  /// What the App read of the chat's pull requests (header state), which the hook already follows.
  pullRequest: HeaderPullRequest | undefined;
  machineName?: string;
  repository?: string;
  cloudRepositoryAvailable?: boolean;
  shell?: HTMLElement | null;
  grants?: readonly AccessGrant[];
  /// The side panel beside the chat, as it opens or closes: the chat's room is measured again.
  beside?: unknown;
  /// A handoff review's form shows: whether the panel lies over the chat is measured against it.
  wide?: boolean;
  /// When an output's diff was last opened (Date.now()).
  openedOutputAt: { readonly current: number };
  /// The person opened it in this pane (useSessionInfo), not only a saved open state.
  asked?: boolean;
  /// That diff's split left no room for the chat beside Session Info: Session Info steps aside.
  onSuppress: () => void;
  /// A row opened something (the folder, Changes, an output): Session Info hides until it is gone
  /// (stepAside.ts); `onStepBack` brings it back at once (the host refused the open).
  onStepAside: () => void;
  onStepBack: () => void;
  registry?: ProcessRegistry;
  subagents?: {
    views: Record<string, AcpmuxRow[]> | undefined;
    asks: ReadonlySet<string>;
    onOpen: (id: string) => void;
  };
  sessions?: { list: readonly StartedSession[]; onOpen: (sessionId: string) => void };
  onSetRunningLimit?: (sessionId: string, maxRunning: number | null, from?: number) => Promise<unknown>;
  /// The chat's Claude workflows (Labs, App.tsx `workflows`), in Background tasks (WorkflowTasks.tsx).
  workflows?: {
    list: readonly WorkflowSummary[];
    onStop?: (id: string) => Promise<unknown>;
    onOpenAgent?: (agent: WorkflowAgent) => void;
  };
  revealed?: { section: SessionInfoSectionId; at: number };
  onRevealed: () => void;
  onStopProcess?: (id: string) => Promise<unknown>;
  onOpenOutput?: (path: string) => void;
  onOpenSourceFile?: (path: string) => unknown;
  onOpenUrl?: (url: string) => void;
  onOpenImage?: (src: string, alt: string, path?: string) => void;
  /// A pasted image's bytes by its id, for its Sources row (direct.ts `promptImage`).
  readPromptImage?: (id: string) => Promise<string | undefined>;
  onOpenFolder?: (path: string) => void;
  /// Reads the chat folder's git changes for Environment's Changes row (changeCounts.ts), with
  /// `onOpenChanges` opening the chat folder's diff beside the chat.
  readChanges?: ReadChanges;
  onOpenChanges?: () => void;
  onSaveEnvironment?: () => Promise<unknown>;
  onReconnectMcp?: (server: string) => Promise<unknown>;
  remoteControl?: { on: boolean; set: (on: boolean) => void };
  onCompact?: () => void;
  onViewPrompt?: () => void;
  onOpenChat?: (sessionId: string) => void;
  /// Asks acpmux for every listed chat's usage now (`_acpmux/sessions` `usage: true`), once each
  /// time the panel shows: what Usage lists is otherwise the last read's, or none at all.
  onShowUsage?: () => void;
  onRender?: () => void;
  onOpenDocument?: (artifact: Artifact) => void;
  onShowCall?: (toolCallId: string) => boolean;
  /// The subagent it lists, while the pane shows one's own view.
  scope?: SubagentScope;
}) {
  onRender?.();
  useCountedRender("session-info:presence");
  const { width, sections } = useSessionInfoState(chat);
  const native = useNativeSessionInfoHost();
  const t = useT();
  const [gallery, setGallery] = useState(false);
  const display = useChatDisplay();
  const sizing = useChatSizing();
  // A column the display owns (its own width) or a zoomed page's is a new object on every call: kept
  // while its numbers are the same, so the placement effect below (the shell's column pin and its
  // CHAT_LAYOUT_EVENT) runs only when the column changes, never once per streamed token.
  const column = useSameValue(chatColumnOf(sizing.width, display, sizing.scale));
  // It slides in from the pane's right edge and back out (ui/presence.ts), keeping its sections
  // while it leaves.
  const presence = usePresence(shown && !native, "right");
  // The computer use card beside the chat narrows its column (the placement effect's pin follows it).
  const preview = useComputerUsePreview() !== null;
  // Leaving: the column slides back while the panel slides out (sessionInfo.css).
  const leaving = !native && !!presence.leaving;
  const drawn = native ? shown : presence.present;
  // The chat's room: the pane less the side panel beside it (a document), whose edge the floating
  // panel keeps clear of, so it never lies over the document.
  const { width: paneWidth, side, height: paneHeight } = usePaneRoom(shell, drawn, beside);
  // How far the chat's content reaches past the column the model expects (chatContentOverflow),
  // read while the panel floats: a panel that would lie over any of it pushes the chat left (Leo,
  // 2026-11-01: "why does the session info not push the layout left ever anymore"). It keeps its
  // reading while pushed, and starts again at 0 each time the panel opens.
  const [overflow, setOverflow] = useState(0);
  // Its three places by the pane's width: in the gutter, pushing into the chat, over the chat.
  const stage = sessionInfoStage(
    display.sessionInfo,
    { width: paneWidth, height: paneHeight },
    width,
    column,
    wide,
    overflow,
  );
  const push = stage === "push";
  const overChat = stage === "overlay";
  // Pushing, its width (narrowed to keep a readable chat) and the room it takes from the chat's right
  // end: by default only what the gutter lacks, so the chat narrows gradually (pushedRoom).
  const panelWidth = push ? pushedWidth(paneWidth, width) : width;
  const room = push ? pushedRoom(paneWidth, panelWidth, column, overflow, pushes(display.sessionInfo)) : 0;
  // How far the panel reaches into the chat's right edge: Find's bar keeps clear of it (sessionInfoClear).
  // The web panel floats over the chat's whole width (its column moves left instead), so the chat's
  // right edge is the pane's; the App's native panel still takes its room from the chat.
  const chatRoom = native ? room : 0;
  const clear = sessionInfoClear(panelWidth, chatRoom);
  const cramped = findBarCramped(paneWidth - chatRoom, clear);
  // In a short pane, over the chat it is a popover that a click elsewhere hides (POPOVER_BELOW_HEIGHT);
  // in a narrow one too (useSessionInfo `narrow`).
  const popover = sessionInfoPopover(paneHeight, overChat) || (overChat && !sessionInfoFits(paneWidth));
  // Open only from a saved state (a new chat, a relaunch), it waits for the person where it would be a
  // popover: it steps aside until the toggle, a running line's count or the palette opens it
  // (cmuxterm-hq#6137: a new chat in a 370px pane opened with the panel over its Retry). A narrow pane
  // holds it in useSessionInfo before it draws.
  // Only a short pane's popover: a narrow pane's is held or kept by useSessionInfo, whose observer can
  // run after this one (a panel showing as the pane narrows must stay, as a popover).
  useLayoutEffect(() => {
    if (!drawn || paneWidth <= 0) return;
    if (!asked && sessionInfoPopover(paneHeight, overChat)) onSuppress();
  }, [drawn, paneWidth, paneHeight, overChat, asked, onSuppress]);
  useEffect(() => {
    const doc = shell?.ownerDocument;
    if (!native || !drawn || !popover || !doc) return;
    const away = (event: PointerEvent) => {
      const target = event.target as Element | null;
      if (target?.closest?.(`${SESSION_INFO_TOGGLE}, ${DISMISS_KEEPERS}`)) return;
      onSuppress();
    };
    doc.addEventListener("pointerdown", away, true);
    return () => doc.removeEventListener("pointerdown", away, true);
  }, [native, drawn, popover, shell, onSuppress]);
  // Over the chat in a taller pane, the card stops above the composer's stack: its height, followed
  // while it lies over the chat (one ResizeObserver on the dock, disconnected when it no longer does,
  // turns popover, or the panel goes). The card's foot animates to it (sessionInfo.css).
  const stopsAboveComposer = overChat && !popover;
  const dockHeight = useDockHeight(shell, drawn && stopsAboveComposer);
  const tabRowHeight = useTabRow().height;
  const sessionInfoTop = sessionInfoTopOffset(tabRowHeight);
  // The column slides only as the panel comes in or leaves (sessionInfo.css data-session-info-sliding);
  // a resize, or a stage that changes with the pane's width, moves it at once, in the frame the pane
  // has its new size, as the rest of the chat moves (agent-pane-running-layout.test.ts).
  const wasDrawn = useRef(false);
  // The placement marker: a pushed column narrows the transcript and not the header
  // (sessionInfo.css). Floating moves nothing.
  useLayoutEffect(() => {
    if (!shell) return;
    if (!drawn) {
      wasDrawn.current = false;
      delete shell.dataset.sessionInfoChatPlacement;
      delete shell.dataset.sessionInfoLeaving;
      delete shell.dataset.sessionInfoSliding;
      shell.style.removeProperty("--acpmux-header-room");
      shell.style.removeProperty(SESSION_INFO_COLUMN);
      shell.style.removeProperty(SESSION_INFO_ROOM);
      shell.dispatchEvent(new (shell.ownerDocument.defaultView?.Event ?? Event)(CHAT_LAYOUT_EVENT));
      return;
    }
    shell.dataset.sessionInfoChatPlacement = push ? "push" : "overlay";
    // Pushing, the transcript's column keeps the width it has in the whole pane on every frame of the
    // slide, and only moves left (pushKeepsColumn, sessionInfo.css).
    // Beside the computer use card (App.tsx data-cu-preview on the chat), the column the chat has
    // closed keeps the card's reserve at its end: pinned at that width, opening rewraps no line.
    const reserve = shell.querySelector(":scope > .acpmux-main[data-cu-preview]") ? COMPUTER_USE_PREVIEW_RESERVE : 0;
    if (push && paneWidth > 0)
      shell.style.setProperty(SESSION_INFO_COLUMN, `${transcriptColumn(paneWidth, column, reserve).width}px`);
    else shell.style.removeProperty(SESSION_INFO_COLUMN);
    // How far the column moves left (sessionInfo.css --acpmux-session-info-shift): the room, back to 0
    // as the panel leaves, so the column slides back with it. The native panel's room is a flex item.
    const shift = push && !native && !leaving ? room : 0;
    const opening = !wasDrawn.current;
    wasDrawn.current = true;
    if (push && !native && (opening || leaving)) shell.dataset.sessionInfoSliding = "";
    // A change that is no open or leave (a resize, a stage the new width picks) after the slide ended:
    // no transition, even before the slide's transitionend has come.
    else if ("sessionInfoSliding" in shell.dataset && !columnSliding(shell)) delete shell.dataset.sessionInfoSliding;
    shell.style.setProperty(SESSION_INFO_ROOM, `${shift}px`);
    shell.toggleAttribute("data-session-info-leaving", leaving);
    shell.dispatchEvent(new (shell.ownerDocument.defaultView?.Event ?? Event)(CHAT_LAYOUT_EVENT));
    // Push always narrows the transcript, not the header: native tabs reserve the tools at the
    // pane's trailing edge. Reuse the measured room (excluding an artifact beside the chat).
    if (paneWidth > 0) shell.style.setProperty("--acpmux-header-room", `${paneWidth}px`);
  }, [shell, drawn, push, paneWidth, column, native, leaving, room, preview]);
  // Find in Chat's bar keeps left of the panel (sessionInfoClear, conversation.css .acpmux-find__bar). Its
  // own effect, so a width drag only moves the bar and fires no chat layout event per frame.
  useLayoutEffect(() => {
    if (!shell || !drawn) return;
    shell.style.setProperty(SESSION_INFO_CLEAR, `${clear}px`);
    return () => {
      shell.style.removeProperty(SESSION_INFO_CLEAR);
    };
  }, [shell, drawn, clear]);
  // Where the chat has no room for Find's bar beside the panel (findBarCramped), the panel steps aside
  // when Find opens, and Find steps aside when the toggle opens the panel over an open bar: the bar is
  // never under it. The panel stays aside after Find closes, until its toggle opens it.
  useEffect(() => {
    if (!shell || !drawn || !cramped) return;
    const away = () => onSuppress();
    if (shell.querySelector(".acpmux-find__bar")) {
      if (asked) shell.dispatchEvent(new (shell.ownerDocument.defaultView?.Event ?? Event)(FIND_HIDE_EVENT));
      else onSuppress();
    }
    shell.addEventListener(FIND_OPEN_EVENT, away);
    return () => shell.removeEventListener(FIND_OPEN_EVENT, away);
  }, [shell, drawn, cramped, asked, onSuppress]);
  // The slide's end: the column's own transition, else the panel's (a slide that moved nothing).
  useEffect(() => {
    const main = shell?.querySelector<HTMLElement>(":scope > .acpmux-main");
    if (!shell || !main) return;
    const ended = (event: TransitionEvent) => {
      if (!("sessionInfoSliding" in shell.dataset)) return;
      if (event.target === main ? event.propertyName === SHIFT : !columnSliding(shell))
        delete shell.dataset.sessionInfoSliding;
    };
    shell.addEventListener("transitionend", ended);
    shell.addEventListener("transitioncancel", ended);
    return () => {
      shell.removeEventListener("transitionend", ended);
      shell.removeEventListener("transitioncancel", ended);
    };
  }, [shell]);
  useLayoutEffect(() => {
    if (!shell) return;
    return () => {
      delete shell.dataset.sessionInfoSliding;
      delete shell.dataset.sessionInfoChatPlacement;
      shell.style.removeProperty("--acpmux-header-room");
      shell.style.removeProperty(SESSION_INFO_COLUMN);
      shell.style.removeProperty(SESSION_INFO_ROOM);
      delete shell.dataset.sessionInfoLeaving;
      shell.dispatchEvent(new (shell.ownerDocument.defaultView?.Event ?? Event)(CHAT_LAYOUT_EVENT));
    };
  }, [shell]);
  // A card under the panel (the computer use live preview) reads where it goes from the shell.
  // The web panel floats at the pane's right, pushing or not; the native one's room is in the chat's row.
  useUnderSessionInfo(shell, drawn, push && native, FLOAT_MARGIN, sessionInfoTop, push && native ? room : undefined);
  // A subagent's panel reads its own rows only: its replies, thoughts and tool calls.
  const rows = scope?.rows ?? snapshot.rows;
  // Measured before paint, so a panel that would cover the chat never draws a frame over it. Again
  // as the pane, the panel or the rows change while it floats or pushes by less than its full room
  // (the chat's width is the pane less that room).
  const reading = drawn && (stage === "float" || (push && room < panelWidth + FLOAT_MARGIN));
  useLayoutEffect(() => {
    if (!drawn) {
      setOverflow(0);
      return;
    }
    if (!shell || !reading || wide) return;
    // The chat's drawn width, not the room's target: while the push slides in, the chat is still wider.
    const main = shell.querySelector<HTMLElement>(":scope > .acpmux-main");
    const drawnChat = main?.getBoundingClientRect().width ?? 0;
    // The web panel's chat keeps the pane's width and its column slides (sessionInfo.css): measured
    // where the column is drawn now, not where the slide ends. Against the slide's end, the rows still
    // at their old place read as overflow, which asked for more room, until the push gave way to lying
    // over the chat.
    const shiftNow = main
      ? Number.parseFloat(
          main.ownerDocument.defaultView?.getComputedStyle(main).getPropertyValue("--acpmux-session-info-shift") ?? "",
        ) || 0
      : 0;
    const next = chatContentOverflow(
      shell,
      push && !native ? paneWidth - shiftNow : drawnChat > 0 ? Math.min(paneWidth, drawnChat) : paneWidth - room,
      column,
      push ? paneWidth : undefined,
    );
    // Only a larger reading sets it: an unchanged one would still draw the panel once (React runs the
    // component before it bails out), once per streamed row while it pushes.
    if (next > overflow) setOverflow((current) => (next > current ? next : current));
  }, [shell, drawn, reading, wide, paneWidth, room, side, width, column, rows.length, push, overflow, native]);
  const scopedAgent = scope?.agent;
  // What the sections list keeps its identity while it holds the same things (sameValue.ts): a snapshot
  // is new objects on every streamed token, and the sections (SessionInfoSections, memoized) then skip it.
  const summary = useSameValue(
    useMemo(
      () => (drawn && scopedAgent ? subagentSummary(snapshot.summary, scopedAgent, rows) : snapshot.summary),
      [drawn, scopedAgent, snapshot.summary, rows],
    ),
  );
  // After `summary`: read before its declaration, it threw on every render (a temporal dead zone).
  const usage = compactingUsage(summary?.usage, summary?.usageStats, summary?.contextBreakdown);
  const made = useSameValue(
    useMemo(
      () => (drawn ? sessionSummary(rows, repository ?? null, summary?.cwd) : undefined),
      [drawn, rows, repository, summary?.cwd],
    ),
  );
  const links = useSameValue(useMemo(() => (drawn ? outputLinks(rows) : []), [drawn, rows]));
  // What the chat made for the person (chatOutputs.ts), read here beside `made` and kept while it is the
  // same files, so the sections need not read the rows for it.
  const outputFiles = useSameValue(
    useMemo(() => (drawn ? chatOutputs(rows, summary?.cwd) : NO_OUTPUT_FILES), [drawn, rows, summary?.cwd]),
  );
  // The plan the transcript's todo list draws. The chat's is the one the client publishes beside its
  // rows (snapshot.progress, liveProgress.ts): the same object until the checklist changes or its turn
  // ends, so a streamed token neither rescans the rows nor recounts the steps (carried from #34933). A
  // subagent's panel gets the parent's snapshot, so it never reads that one: its plan comes from its
  // own live rows (not `sectionRows`, which keep their identity until a row is added), so a step ticked
  // in place shows here at once.
  const live = snapshot.progress;
  const livePlan = useMemo<SessionInfoPlan | undefined>(
    () => (live ? { entries: live.plan, ended: Boolean(live.ended), done: live.completed } : undefined),
    [live],
  );
  const scopedWorking = scopedAgent?.state === "running";
  const scopedPlan = useSameValue(
    useMemo(
      () => (drawn && scopedAgent ? currentPlan(rows, scopedWorking) : undefined),
      [drawn, scopedAgent, rows, scopedWorking],
    ),
  );
  const plan = scopedAgent ? scopedPlan : drawn ? livePlan : undefined;
  const artifacts = useMemo(() => (drawn ? chatGallery(rows).length : 0), [drawn, rows]);
  const documents = useSameValue(useMemo(() => (drawn ? outputArtifacts(rows) : []), [drawn, rows]));
  const views = subagents?.views;
  const asks = subagents?.asks;
  const scopedAgents = scope?.agents;
  const agents = useSameValue(
    useMemo(
      () => (drawn ? (scopedAgents ?? [...subagentsIn(rows, views).values()]) : []),
      [drawn, scopedAgents, rows, views],
    ),
  );
  // Environment's Changes: the folder's git changes, read as the panel shows and at each turn's end.
  const edits = useChangeCounts(
    readChanges,
    drawn,
    `${snapshot.sessionId ?? ""}\u0000${snapshot.isWorking ? "working" : "idle"}`,
  );
  const chatRows = snapshot.rows;
  const transcriptTasks = useSameValue(
    useMemo(
      () => (scope && made ? withChatEnds(made.backgroundTasks, chatRows) : made?.backgroundTasks),
      [scope, made, chatRows],
    ),
  );
  const allProcesses = registry?.processes;
  const processes = useSameValue(
    useMemo(
      () => (drawn && scope && allProcesses ? subagentProcesses(allProcesses, rows) : allProcesses),
      [drawn, scope, allProcesses, rows],
    ),
  );
  const waiting = useSameValue(
    useMemo(() => (drawn && asks ? waitingSubagents(asks, views) : new Set<string>()), [drawn, asks, views]),
  );
  // The rest of what the sections take from the snapshot and the App, kept the same way.
  // What the sections draw of the other chats acpmux lists, not the list itself: the list is new each
  // time any chat anywhere changes (its status, its indicator, its time), which drew every section
  // again, while a scroll ran too, though they show none of it. Usage's rows (usageEntries.ts) and Also
  // working here's (useAlsoHere) keep their identity until what they draw changes.
  const everyChat = drawn && !scope ? snapshot.sessions : undefined;
  const usageSessions = useSameValue(useMemo(() => usageEntries(everyChat), [everyChat]));
  const alsoHereRows = useSameValue(useAlsoHere(summary?.sessionId, everyChat));
  const peerKinds = useSameValue(snapshot.peerKinds);
  // Where the chat runs beyond its summary (its route and listed peer), for Environment's machine row.
  const place = useSameValue(chatPlace(snapshot));
  const startedList = useSameValue(scope ? undefined : sessions?.list);
  const workflowList = useSameValue(scope ? undefined : workflows?.list);
  // A subagent, a started chat or a workflow's agent opens beside the chat (its own pane): Session Info
  // steps aside for it as for the folder and Changes, and is back once that pane closes (Lucas,
  // 2026-11-06: "clicking on a subagent will close the session info summary menu, like how it does for
  // files and changes"). One shown here in place moves the panel to its scope, which brings it back.
  const openSubagentOwn = useStableCallback(subagents?.onOpen);
  const openSessionOwn = useStableCallback(sessions?.onOpen);
  const openWorkflowAgentOwn = useStableCallback(workflows?.onOpenAgent);
  const onOpenSubagent = useMemo(
    () =>
      openSubagentOwn &&
      ((id: string) => {
        onStepAside();
        openSubagentOwn(id);
      }),
    [openSubagentOwn, onStepAside],
  );
  const onOpenSession = useMemo(
    () =>
      openSessionOwn &&
      ((sessionId: string) => {
        onStepAside();
        openSessionOwn(sessionId);
      }),
    [openSessionOwn, onStepAside],
  );
  const onOpenWorkflowAgent = useMemo(
    () =>
      openWorkflowAgentOwn &&
      ((agent: WorkflowAgent) => {
        onStepAside();
        openWorkflowAgentOwn(agent);
      }),
    [openWorkflowAgentOwn, onStepAside],
  );
  const onStopWorkflow = useStableCallback(workflows?.onStop);
  const setRunningLimit = useStableCallback(onSetRunningLimit);
  // The tool calls the loaded transcript holds, for a task row's Show call in a chat whose terminal
  // cannot open here, and for a wakeup or cron job, which shows the call that made it on any chat:
  // read here, so a call added to an existing row reaches the sections, and kept while it is the same
  // set. A chat on this Mac with nothing scheduled opens its terminals instead and reads none.
  const readsCalls = !!onShowCall && (!opensProcessTerminal(summary) || (made?.scheduled?.length ?? 0) > 0);
  const toolCalls = useSameValue(
    useMemo(() => (drawn && readsCalls ? toolCallIds(rows) : undefined), [drawn, readsCalls, rows]),
  );
  // The rows the sections read for the chat's gallery (its images: `artifacts`), whether it has any, and
  // the tool calls they show where `toolCalls` is not read: the same rows until the chat has rows or
  // none, its gallery or what it made changes, a turn starts or ends, or the panel lists another agent.
  // Not each streamed token's copy, and not each row added: a tool call that makes nothing the panel
  // shows draws none of it (Outputs reads `outputFiles`, Tasks reads `toolCalls`).
  const listing = scope?.agent.id;
  const working = snapshot.isWorking;
  const any = rows.length > 0;
  const galleryRows = useRef({ rows, any, artifacts, listing, working, outputFiles, toolCalls });
  if (
    galleryRows.current.any !== any ||
    galleryRows.current.artifacts !== artifacts ||
    galleryRows.current.listing !== listing ||
    galleryRows.current.working !== working ||
    galleryRows.current.outputFiles !== outputFiles ||
    galleryRows.current.toolCalls !== toolCalls
  )
    galleryRows.current = { rows, any, artifacts, listing, working, outputFiles, toolCalls };
  const sectionRows = galleryRows.current.rows;
  const banner = useMemo(
    () =>
      scope && SUBAGENT_HEADER !== "title" ? <SubagentBanner scope={scope} variant={SUBAGENT_HEADER} /> : undefined,
    [scope],
  );
  // Every pull request's title, state, lines and checks from the App's cache, the folder's live
  // read over it (changesStatus.ts); asked for only while Changes is unfolded.
  const changes = useMemo(() => visibleChanges(made?.pullRequests ?? [], {}), [made?.pullRequests]);
  const prUrls = useStableUrls(changes);
  const { statuses: cached } = useChangesStatuses(prUrls, drawn, drawn && sections.changes);
  const statuses = useMemo(() => withHeader(cached, headerStatus(pullRequest)), [cached, pullRequest]);
  // An output's diff opens beside the chat. With Settings Push always, when that split leaves too
  // little room for a readable chat beside Session Info, it steps aside until the toggle opens it
  // again. By default it stays, pushing or, under 648px, over the chat above the composer.
  const roomy = !pushes(display.sessionInfo) || sessionInfoFits(paneWidth);
  const roomyRef = useRef(roomy);
  // Environment's project opens in Files as a tab right of the chat (App.tsx `onOpenFolder`), its
  // Changes the folder's diff there, and an Outputs file in cmux's file pages: Session Info steps aside
  // so what the row opened is what shows, and comes back once it is closed (stepAside.ts; Leo,
  // 2026-10-27: "why am i sent to a whole new thing instead of a tab opening on the right?").
  const openFolder = useMemo(
    () =>
      onOpenFolder &&
      ((path: string) => {
        onStepAside();
        onOpenFolder(path);
      }),
    [onOpenFolder, onStepAside],
  );
  const openChanges = useMemo(
    () =>
      onOpenChanges &&
      (() => {
        onStepAside();
        onOpenChanges();
      }),
    [onOpenChanges, onStepAside],
  );
  const openOutputPath = useCallback(
    (path: string) => {
      onStepAside();
      // A refused open (no gesture, a denied path, a missing file) shows nothing: the panel is back.
      void openOutputFile(path).then((opened) => {
        if (!opened) onStepBack();
      });
    },
    [onStepAside, onStepBack],
  );
  useEffect(() => {
    const was = roomyRef.current;
    roomyRef.current = roomy;
    if (was && !roomy && Date.now() - openedOutputAt.current < SPLIT_SETTLE_MS) onSuppress();
  }, [roomy, openedOutputAt, onSuppress]);
  // AppKit is above the page. Existing page popovers temporarily take the pane and restore it on close.
  if (native)
    return (
      <>
        {/* The App draws the panel over the page (AgentPaneView+SessionInfo.swift sessionInfoFrame: the
            pushed width and the float margin from the pane's right edge, left of a side panel). Pushing,
            the page keeps that same room in the shell's row, so the chat narrows beside the panel
            instead of lying under it (cmuxterm-hq#6137). */}
        {push && drawn && !gallery && room > 0 && (
          <div
            className="acpmux-session-info-room"
            aria-hidden="true"
            style={{
              width: Math.max(0, room - FLOAT_MARGIN),
              marginRight: Math.min(room, FLOAT_MARGIN),
            }}
          />
        )}
        <NativeSessionInfo
          key={scope ? `${snapshot.sessionId}:subagent:${scope.agent.id}` : snapshot.sessionId}
          shown={drawn && !gallery}
          width={panelWidth}
          top={nativeTop(shell, tabRowHeight)}
          side={side}
          foot={stopsAboveComposer ? dockHeight : undefined}
          overChat={overChat}
          label={t("sessionInfo.title")}
          title={scope ? `${t("sessionInfo.subagent")} · ${scope.agent.name}` : undefined}
          onBack={scope?.onBack}
          backLabel={scope ? subagentBackLabel(t, scope.parent) : undefined}
          summary={summary}
          usage={usage}
          plan={plan}
          machineName={machineName}
          peerKinds={snapshot.peerKinds}
          place={place}
          repository={repository}
          grants={scope ? undefined : grants}
          cloudRepositoryAvailable={cloudRepositoryAvailable}
          made={made}
          links={links}
          artifacts={artifacts}
          documents={documents}
          rows={rows}
          agents={agents}
          waiting={waiting}
          statuses={statuses}
          processes={processes ?? []}
          listed={registry?.listed ?? false}
          transcriptTasks={transcriptTasks ?? []}
          sessions={scope ? [] : (sessions?.list ?? [])}
          workflows={scope ? [] : (workflows?.list ?? [])}
          agent={scope?.agent}
          onOpenSubagent={subagents?.onOpen}
          onOpenSession={sessions?.onOpen}
          allSessions={scope ? undefined : snapshot.sessions}
          onOpenChat={onOpenChat}
          onShowUsage={scope ? undefined : onShowUsage}
          onSetRunningLimit={onSetRunningLimit}
          onStopWorkflow={workflows?.onStop}
          onOpenWorkflowAgent={workflows?.onOpenAgent}
          onStopProcess={onStopProcess}
          onOpenOutput={onOpenOutput}
          onOpenSourceFile={onOpenSourceFile}
          onOpenUrl={onOpenUrl}
          onOpenDocument={onOpenDocument}
          onOpenArtifacts={rows.length > 0 ? () => setGallery(true) : undefined}
          onReconnectMcp={onReconnectMcp}
          remoteControl={scope ? undefined : remoteControl}
          onCompact={scope ? undefined : onCompact}
          onViewPrompt={scope ? undefined : onViewPrompt}
          onOpenFolder={openFolder}
          onShowCall={onShowCall}
          revealed={revealed}
          onRevealed={onRevealed}
        />
        {gallery && (
          <GalleryDialog
            rows={rows}
            onClose={() => setGallery(false)}
            onOpenImage={
              onOpenImage &&
              ((src, alt, path) => {
                setGallery(false);
                onOpenImage(src, alt, path);
              })
            }
          />
        )}
      </>
    );
  if (!drawn) return null;
  return (
    <MemoSessionInfoPanel
      title={scope && SUBAGENT_HEADER === "title" ? <SubagentTitle scope={scope} /> : undefined}
      width={panelWidth}
      placement={push ? "push" : "overlay"}
      overlap={0}
      // Floating or pushing, it starts under the chat header (styles.css --acpmux-header-height; in the
      // pane's tab row, the row's height), so the header's tools, its own toggle among them, stay in reach.
      under={sessionInfoTop}
      // Floating or pushing, it stays left of a side panel beside the chat (its width).
      side={side}
      foot={stopsAboveComposer ? dockHeight : undefined}
      onDismiss={popover ? onSuppress : undefined}
      presence={presence}
    >
      {/* Another chat's sections start drawn with what that chat has: none of its rows drops in. */}
      <SessionInfoSections
        key={scope ? `${snapshot.sessionId}:subagent:${scope.agent.id}` : snapshot.sessionId}
        banner={banner}
        agent={scope?.agent}
        summary={summary}
        machineName={machineName}
        peerKinds={peerKinds}
        place={place}
        repository={repository}
        cloudRepositoryAvailable={cloudRepositoryAvailable}
        made={made}
        artifacts={artifacts}
        documents={documents}
        rows={sectionRows}
        outputFiles={outputFiles}
        plan={plan}
        toolCalls={toolCalls}
        agents={agents}
        waiting={waiting}
        onOpenSubagent={onOpenSubagent}
        statuses={statuses}
        processes={processes}
        listed={registry?.listed}
        transcriptTasks={transcriptTasks}
        // The chats the chat's agent started are the chat's.
        sessions={startedList}
        workflows={workflowList}
        onStopWorkflow={onStopWorkflow}
        onOpenWorkflowAgent={onOpenWorkflowAgent}
        onOpenSession={onOpenSession}
        // Usage lists every chat acpmux lists; a subagent's own panel has no Usage.
        usageSessions={usageSessions}
        alsoHere={alsoHereRows}
        onOpenChat={onOpenChat}
        onShowUsage={scope ? undefined : onShowUsage}
        onSetRunningLimit={setRunningLimit}
        revealed={revealed}
        onRevealed={onRevealed}
        onStopProcess={onStopProcess}
        sections={sections}
        onSection={setSessionInfoSection}
        onOpenSourceFile={onOpenSourceFile}
        onOpenUrl={onOpenUrl}
        onOpenImage={onOpenImage}
        readPromptImage={readPromptImage}
        onOpenFolder={openFolder}
        edits={edits}
        onOpenChanges={openChanges}
        onOpenOutputFile={openOutputPath}
        // Save keeps the chat's machine and folder, not a subagent's.
        onSaveEnvironment={scope ? undefined : onSaveEnvironment}
        onReconnectMcp={onReconnectMcp}
        remoteControl={scope ? undefined : remoteControl}
        // Compact ends the chat's context, not a subagent's.
        onCompact={scope ? undefined : onCompact}
        onViewPrompt={scope ? undefined : onViewPrompt}
        onOpenDocument={onOpenDocument}
        onShowCall={onShowCall}
      />
    </MemoSessionInfoPanel>
  );
});

/// The panel's frame: its width, its place beside the chat (push) or floating in the chat's right
/// gutter (overlay), and the drag handle on its left edge (a double-click puts the width back). With
/// `presence`, it enters from and leaves toward the pane's right edge. The main panel has no head and
/// no close button: its header toggle and Esc close it (Leo, 2026-10-24: "you still didn't remove the,
/// like, top bit with the closing mark. It doesn't— it's not necessary"), and it steps aside whenever a
/// view takes the pane, so its toggle is always in reach. A scoped subagent supplies a title as its own
/// breadcrumb. It starts `under` (a CSS length: the chat header's height) below the pane's top, at the
/// top by default.
export function SessionInfoPanel({
  width,
  placement,
  under,
  foot,
  side = 0,
  overlap = 0,
  onDismiss,
  presence,
  onClose,
  title,
  chrome = "close",
  children,
}: {
  width: number;
  placement: SessionInfoPlacement;
  under?: string;
  /// Over the chat's column, the composer's stack height in px: the card stops above it.
  foot?: number;
  /// A popover (sessionInfoPopover): a press anywhere but the panel, its toggle, or a menu, popup or
  /// dialog it opened hides it until the toggle opens it again.
  onDismiss?: () => void;
  /// Floating, how far from the pane's right edge the chat ends (the side panel's width): the panel
  /// floats in the chat's gutter, left of the side panel.
  side?: number;
  /// Pushing, how much of its width and margin lies over the chat's own gutter instead of taking room
  /// from the chat (SessionInfo.tsx pushedRoom): a negative left margin (sessionInfo.css).
  overlap?: number;
  presence?: Presence;
  /// Its own close button, in the gallery's chrome choices only.
  onClose?: () => void;
  /// Its head's title in place of "Session Info": a subagent's panel names the subagent (SubagentTitle).
  title?: ReactNode;
  /// With `onClose`, the gallery's chrome choices: a floating close, the old title row, a compact
  /// close-only row.
  chrome?: "title" | "close" | "compact-close";
  children: ReactNode;
}) {
  useCountedRender("session-info:panel");
  const t = useT();
  const frame = useRef<HTMLElement | null>(null);
  const drag = useRef<{ right: number } | undefined>(undefined);
  // Glass only where the chat runs under it: floating over the chat's column (a foot) or as a popover.
  // Pushed beside the chat, or in the empty gutter, its sections sit on the pane with no card behind
  // them, as the native panel draws it (#32661; Leo, 2026-11-02: "we still HAVE AN ASININE BACKGROUND").
  const glass = placement === "overlay" && (foot !== undefined || onDismiss !== undefined);
  // Floating over the chat (the narrow pane's Summary popover), the chat under it blurs itself there in
  // a see-through Chromium page (ui/glass/seeThroughBlur.ts), as WebKit's backdrop draws it, so its
  // text never reads through the glass (Leo 2026-10-30: "I don't like the non-glassness"). Pushing,
  // or in the gutter, it covers nothing.
  useSeeThroughBlur(frame, glass, chatUnderGlass, chatGlass);
  // The transcript leaves the panel's box out while it shows (chatCut.ts), so nothing scrolls under
  // it: its pixels hold still while the chat scrolls (Leo, 2026-11-03: "the session info thing not
  // flicker EVER when im scrolling"). Its place re-measures when it moves.
  useChatCut(frame, !presence?.leaving, `${placement}:${width}:${foot ?? ""}:${side}:${overlap}:${under ?? ""}`);
  // The foot animates only once it has been drawn at its first measure: the open draws it at once.
  const footKnown = foot !== undefined && foot > 0;
  // Only a foot that goes down (the composer's stack shrank) glides. One that rises (the stack grew: the
  // running tray coming in, a queued prompt, a taller draft) moves in the frame the stack moved, with it:
  // gliding, the card's lower part lay over the grown stack for the glide, and that overlap switched
  // its glass between the App's and the page's own (data-glass-keeps-underlay, seeThroughBlur.ts) and
  // back, a flash each time a tool call brought the tray in or out (Leo, 2026-11-07: "im still seeing
  // session info flash ... when im slowly scrolling down as you're doing the thinking/tool calls").
  const [footWas, setFootWas] = useState(foot);
  const [footRises, setFootRises] = useState(false);
  if (foot !== footWas) {
    setFootWas(foot);
    setFootRises(foot !== undefined && footWas !== undefined && foot > footWas);
  }
  const [footSettled, setFootSettled] = useState(false);
  useEffect(() => {
    if (!footKnown) {
      setFootSettled(false);
      return;
    }
    const frameId = requestAnimationFrame(() => setFootSettled(true));
    return () => cancelAnimationFrame(frameId);
  }, [footKnown]);
  // A popover hides on a press elsewhere: one capture listener on the document while it is one.
  useEffect(() => {
    const doc = frame.current?.ownerDocument;
    if (!onDismiss || !doc) return;
    const away = (event: PointerEvent) => {
      const target = event.target as Element | null;
      if (!target || typeof target.closest !== "function") return;
      if (frame.current?.contains(target)) return;
      if (target.closest(SESSION_INFO_TOGGLE)) return;
      const layer = target.closest(DISMISS_KEEPERS);
      // A containing dialog is below this panel, so pressing its content can dismiss the panel.
      if (layer && !layer.contains(frame.current)) return;
      // Capture precedes a child popup's outside-press handler. Let that popup consume this
      // dismissal even though its popup is portalled; only triggers owned by this panel count.
      if (frame.current?.querySelector('[aria-haspopup][data-popup-open], [aria-haspopup][aria-expanded="true"]'))
        return;
      onDismiss();
    };
    doc.addEventListener("pointerdown", away, true);
    return () => doc.removeEventListener("pointerdown", away, true);
  }, [onDismiss]);
  return (
    <aside
      {...presence?.props}
      ref={(node) => {
        frame.current = node;
        presence?.props.ref(node);
      }}
      inert={presence?.leaving}
      className={glass ? "ui-glass ui-glass-floats acpmux-session-info" : "acpmux-session-info"}
      // Its glass is the App's own popover glass, drawn under the page (ui/glass/hostGlass.ts; Leo,
      // 2026-11-06: "the f***ing session info. Like, wait, why the f*** is this not glass?").
      data-host-glass={glass ? "popover" : undefined}
      data-placement={placement}
      data-chrome={title ? "title" : onClose ? chrome : "none"}
      data-over-chat={foot !== undefined ? "" : undefined}
      data-popover={onDismiss ? "" : undefined}
      data-foot-moves={footKnown && footSettled && !footRises ? "" : undefined}
      style={
        {
          width,
          // Pushing, its enter and exit run its right margin from minus this (sessionInfo.css).
          "--acpmux-session-info-width": `${width}px`,
          ...(under ? { "--acpmux-session-info-top": under } : {}),
          ...(foot !== undefined ? { "--acpmux-session-info-foot": `${foot}px` } : {}),
          ...(side > 0 ? { "--acpmux-session-info-side": `${side}px` } : {}),
          ...(overlap > 0 ? { "--acpmux-session-info-overlap": `${overlap}px` } : {}),
        } as CSSProperties
      }
      aria-label={t("sessionInfo.title")}
    >
      <div
        className="acpmux-session-info__resize"
        aria-hidden="true"
        onPointerDown={(event) => {
          if (event.button !== 0 || !frame.current) return;
          event.preventDefault();
          event.currentTarget.setPointerCapture?.(event.pointerId);
          drag.current = { right: frame.current.getBoundingClientRect().right };
          frame.current.dataset.resizing = "";
        }}
        onPointerMove={(event) => {
          if (drag.current) setSessionInfoWidth(drag.current.right - event.clientX, false);
        }}
        onPointerUp={(event) => {
          if (!drag.current) return;
          setSessionInfoWidth(drag.current.right - event.clientX);
          drag.current = undefined;
          if (frame.current) delete frame.current.dataset.resizing;
        }}
        onPointerCancel={() => {
          drag.current = undefined;
          if (frame.current) delete frame.current.dataset.resizing;
        }}
        onDoubleClick={() => setSessionInfoWidth(SESSION_INFO_WIDTH.fallback)}
      />
      {title || (onClose && (chrome === "title" || chrome === "compact-close")) ? (
        <div className="acpmux-session-info__head">
          {title ??
            (chrome === "title" ? <span className="acpmux-session-info__title">{t("sessionInfo.title")}</span> : null)}
          {onClose && (
            <button
              type="button"
              className="acpmux-session-info-icon-button acpmux-session-info__close"
              aria-label={t("sessionInfo.close")}
              {...tooltipProps(t("sessionInfo.close"), undefined)}
              onClick={onClose}
            >
              <Icon name="action.close" size={12} />
            </button>
          )}
        </div>
      ) : (
        onClose && (
          <button
            type="button"
            className="acpmux-session-info-icon-button acpmux-session-info__close acpmux-session-info__close--floating"
            aria-label={t("sessionInfo.close")}
            {...tooltipProps(t("sessionInfo.close"), undefined)}
            onClick={onClose}
          >
            <Icon name="action.close" size={12} />
          </button>
        )
      )}
      {children}
    </aside>
  );
}

/// How the panel lays out its sections. Leo, 2026-10-22: "and this session rail is tmi and too many
/// boxes?". It drew eight hairline cards: two of them one line each (Context, Connectors), two of them
/// the same kind of thing (Servers and Background tasks, both background commands). No section is a
/// card now, and Servers' rows head Background tasks. The three ways the gallery shows
/// (`agent-pane.chat-inspector` `layout-*`):
/// - `glance`, shipped: three blocks with a hairline between them and no box. Where it runs: the
///   Environment's rows with no title over them, then Context and Connectors as one row each, which
///   open in place. What it made: Changes, Outputs. What it runs: Subagents, Background tasks.
/// - `rules`: every section keeps its title, Environment's too, with a hairline between each.
/// - `groups`: the same three blocks as `glance`, each one hairline card.
export type RailLayout = "glance" | "rules" | "groups";
export const RAIL_LAYOUT: RailLayout = "glance";

/// No files made (a stable value, so the sections' memo holds).
const NO_OUTPUT_FILES: ReturnType<typeof chatOutputs> = [];

/// The tool calls in `rows`, by id.
const toolCallIds = (rows: readonly AcpmuxRow[]): ReadonlySet<string> =>
  new Set(rows.flatMap((row) => (row.items ?? []).flatMap((item) => (item.tool?.id ? [item.tool.id] : []))));

/// The panel frame for SessionInfoPresence, drawn again only when what it is handed changes
/// (samePanelProps.ts): a snapshot that changes nothing it draws leaves the frame and its sections be.
const MemoSessionInfoPanel = memo(function MemoSessionInfoPanel(props: Parameters<typeof SessionInfoPanel>[0]) {
  return <SessionInfoPanel {...props} />;
}, samePanelProps);

/// The sections for one chat, drawn again only when a prop changes: SessionInfoPresence hands it the
/// same lists while they hold the same things, so a streamed token, a tool call that makes nothing or a
/// usage tick draws nothing here.
const SessionInfoSections = memo(function SessionInfoSections(props: Parameters<typeof SessionInfo>[0]) {
  useCountedRender("session-info:sections");
  return <SessionInfo {...props} />;
});

/// The sections for one chat.
export function SessionInfo({
  summary,
  machineName,
  peerKinds,
  place,
  repository,
  cloudRepositoryAvailable,
  made,
  artifacts = 0,
  documents = [],
  rows = [],
  outputFiles,
  plan,
  toolCalls,
  agents = [],
  waiting = new Set(),
  onOpenSubagent,
  statuses = {},
  processes = [],
  listed = false,
  transcriptTasks = [],
  sessions = [],
  workflows = [],
  onStopWorkflow,
  workflowAgentRowVariant,
  onOpenWorkflowAgent,
  onOpenSession,
  onSetRunningLimit,
  revealed,
  onRevealed,
  onStopProcess,
  sections,
  onSection,
  onOpenSourceFile,
  onOpenUrl,
  onOpenImage,
  readPromptImage,
  onOpenDocument,
  remoteControl,
  onSaveEnvironment,
  onReconnectMcp,
  onCompact,
  onViewPrompt,
  onOpenFolder,
  edits,
  onOpenChanges,
  onOpenOutputFile,
  onShowCall,
  allSessions,
  usageSessions = allSessions,
  alsoHere: shownAlsoHere,
  onOpenChat,
  onShowUsage,
  usageOwnRowLayout,
  usageCacheLayout,
  banner,
  agent,
  layout = RAIL_LAYOUT,
  projectRowLook,
  remoteControlIcon,
  more,
  onMore,
  compactLook = "more",
  imessage: imessageFixture,
}: {
  summary?: Summary;
  machineName?: string;
  peerKinds?: Readonly<Record<string, "ssh" | "cloud">>;
  /// The page's route to the chat (chatMachine.ts `chatPlace`).
  place?: ChatPlace;
  repository?: string;
  cloudRepositoryAvailable?: boolean;
  /// What the chat produced (sessionSummary).
  made?: Pick<SessionSummary, "outputs" | "pullRequests" | "scheduled"> & Partial<Pick<SessionSummary, "sources">>;
  artifacts?: number;
  /// The documents the chat produced (OutputsSection `outputArtifacts`).
  documents?: readonly OutputArtifact[];
  /// Opens a document in the side panel beside the chat.
  onOpenDocument?: (artifact: Artifact) => void;
  /// The chat's rows, for its gallery.
  rows?: readonly AcpmuxRow[];
  /// What the chat made for the person (chatOutputs.ts), where the caller reads it; else read from `rows`.
  outputFiles?: ReturnType<typeof chatOutputs>;
  /// The agent's current plan (ProgressSection.tsx `currentPlan`); without one, no Progress.
  plan?: SessionInfoPlan;
  /// The tool calls the loaded transcript holds (toolCallIds), where the caller reads them; else read
  /// from `rows`.
  toolCalls?: ReadonlySet<string>;
  agents?: readonly Subagent[];
  waiting?: ReadonlySet<string>;
  onOpenSubagent?: (id: string) => void;
  /// What the App read of the pull requests, by URL.
  statuses?: Readonly<Record<string, SessionInfoPullRequestStatus>>;
  /// The chat's background processes, in the order they started.
  processes?: readonly SessionInfoProcess[];
  /// The registry answered a listing for the chat: a transcript task it does not list no longer
  /// runs (processes.ts `backgroundCommands`).
  listed?: boolean;
  /// The background commands the transcript knows (sessionSummary `backgroundTasks`): Claude's
  /// background Bash, Ctrl-B's included, which the registry may not list.
  transcriptTasks?: readonly SummaryBackgroundTask[];
  /// The chats the agent started, listed under Subagents.
  sessions?: readonly StartedSession[];
  onOpenSession?: (sessionId: string) => void;
  /// Sets or drops the chat's running limit (SubagentLimitStepper.tsx); without it the limit only reads.
  onSetRunningLimit?: (sessionId: string, maxRunning: number | null, from?: number) => Promise<unknown>;
  /// The chat's Claude workflows (Labs): they head Background tasks, and leave Subagents.
  workflows?: readonly WorkflowSummary[];
  onStopWorkflow?: (id: string) => Promise<unknown>;
  /// Gallery-only alternatives for the live workflow agent row.
  workflowAgentRowVariant?: WorkflowAgentRowVariant;
  /// Opens a workflow agent through its workflow transcript bridge.
  onOpenWorkflowAgent?: (agent: WorkflowAgent) => void;
  /// The section a running line's count opened: scrolled into view (`at` tells one ask from the next).
  revealed?: { section: SessionInfoSectionId; at: number };
  /// The reveal has scrolled: the caller forgets it.
  onRevealed?: () => void;
  onStopProcess?: (id: string) => Promise<unknown>;
  /// Which sections are open; uncontrolled without `onSection`.
  sections?: SessionInfoSections;
  onSection?: (id: SessionInfoSectionId, open: boolean) => void;
  onOpenSourceFile?: (path: string) => unknown;
  onOpenUrl?: (url: string) => void;
  onOpenImage?: (src: string, alt: string, path?: string) => void;
  /// A pasted image's bytes by its id, for its Sources row (direct.ts `promptImage`).
  readPromptImage?: (id: string) => Promise<string | undefined>;
  remoteControl?: { on: boolean; set: (on: boolean) => void };
  onSaveEnvironment?: () => Promise<unknown> | void;
  /// Reconnects one of the chat's failed MCP servers by name (`_acpmux/mcp/reconnect`).
  onReconnectMcp?: (server: string) => Promise<unknown>;
  /// Sends the chat's agent its `/compact`: Context's Compact session (ContextSection), live while a
  /// turn runs (the /compact queues behind it), and Usage's next step for its context (UsageSection.tsx).
  onCompact?: () => void;
  /// Context's View Prompt (useSessionInfo's).
  onViewPrompt?: () => void;
  /// Every chat acpmux lists, this Mac's and its peers', for Usage (UsageSection.tsx); unset in a
  /// subagent's own panel.
  allSessions?: readonly AcpmuxSessionEntry[];
  /// In place of `allSessions`, what the sections draw of it (SessionInfoPresence): Usage's chats
  /// (usageEntries.ts) and the chats working here (alsoHere.ts).
  usageSessions?: readonly UsageEntry[];
  alsoHere?: readonly AlsoHere[];
  /// Opens one of them.
  onOpenChat?: (sessionId: string) => void;
  /// Asks acpmux for every listed chat's usage now (`_acpmux/sessions` `usage: true`), once each
  /// time the panel shows: what Usage lists is otherwise the last read's, or none at all.
  onShowUsage?: () => void;
  /// Gallery-only alternatives for the Usage section's own-metrics leading column.
  usageOwnRowLayout?: UsageOwnRowLayout;
  /// Gallery-only alternatives for Usage's prompt cache numbers (two rows, or one).
  usageCacheLayout?: UsageCacheLayout;
  /// Opens the chat's project folder in the Files tree beside the chat.
  onOpenFolder?: (path: string) => void;
  /// Opens an Outputs file (the panel's own: Session Info steps aside for it); the host's path open
  /// without it.
  onOpenOutputFile?: (path: string) => void;
  /// The chat folder's git changes (changeCounts.ts): Environment's Changes row, with `onOpenChanges`
  /// opening the chat folder's diff beside the chat.
  edits?: { additions: number; deletions: number };
  onOpenChanges?: () => void;
  /// Shows the Bash call that started a background command in the transcript: what its row opens
  /// in a chat whose terminal cannot open here (TasksSection).
  onShowCall?: (toolCallId: string) => boolean;
  /// The body's first line: whose panel it is (a subagent's, SubagentBanner).
  banner?: ReactNode;
  /// The subagent it lists: its Context is the tokens and tool uses the harness reports for it.
  agent?: Subagent;
  /// How its sections are laid out (`RAIL_LAYOUT`); the gallery shows the others.
  layout?: RailLayout;
  /// How Environment's project row reads (EnvironmentSection's `name`); the gallery shows the others.
  projectRowLook?: ProjectRowLook;
  /// Remote Control's row icon (EnvironmentSection's REMOTE_CONTROL_ICON); the gallery shows the others.
  remoteControlIcon?: string;
  /// The panel's Show more is open (its less-used sections show); the pane's saved choice without it.
  more?: boolean;
  onMore?: (more: boolean) => void;
  /// How the default view stays short (SessionInfoGroup.tsx); the gallery shows the others.
  compactLook?: SessionInfoCompactLook;
  /// Gallery fixtures; false suppresses the Mac-only connector.
  imessage?: IMessageView | false;
}) {
  const t = useT();
  const liveIMessage = useIMessage(imessageFixture === undefined);
  const imessage = imessageFixture || liveIMessage;
  const language = usePaneLanguage();
  const sessionInfoState = useSessionInfoState();
  const showMore = more ?? sessionInfoState.more;
  const setMore = onMore ?? setSessionInfoMore;
  const stored = sessionInfoState.sections;
  const state = sections ?? stored;
  const fold = (id: SessionInfoSectionId) => (next: boolean) => (onSection ?? setSessionInfoSection)(id, next);
  const imessageStatus = imessage?.data.status;
  useEffect(() => {
    if (!imessageStatus || imessageStatus === "connected" || !claimSessionInfoIMessageReveal()) return;
    (onSection ?? setSessionInfoSection)("connectors", true);
  }, [imessageStatus, onSection]);
  useEffect(() => {
    if (imessage?.expanded) (onSection ?? setSessionInfoSection)("connectors", true);
  }, [imessage?.expanded, onSection]);
  const [gallery, setGallery] = useState(false);
  const usage = compactingUsage(summary?.usage, summary?.usageStats, summary?.contextBreakdown);
  const known = usage !== undefined && usage.size > 0;
  // As the composer's context ring reads it (ComposerPickers ContextRing).
  const percent = known ? Math.round(Math.min(1, Math.max(0, usage.used / usage.size)) * 100) : 0;
  const { servers, tasks: commands } = sessionInfoLists(processes, transcriptTasks, listed);
  // A chat on this Mac opens a task's terminal; elsewhere a row shows the call that started it,
  // when the loaded transcript holds it. A wakeup or cron job shows the call that made it on any
  // chat (TasksSection `scheduledRow`). Read only then, so a local chat with nothing scheduled adds
  // no pass over its rows.
  const local = opensProcessTerminal(summary);
  const showsCalls =
    !!onShowCall && ((!local && commands.some((command) => command.toolCallId)) || (made?.scheduled?.length ?? 0) > 0);
  const calls = useMemo(
    () => (showsCalls ? (toolCalls ?? toolCallIds(rows)) : undefined),
    [showsCalls, toolCalls, rows],
  );
  const body = useRef<HTMLDivElement>(null);
  // Rows scrolled past the body's top or bottom fade at that edge (scrollEdges.ts, sessionInfo.css)
  // instead of being cut off. It stops following when the body unmounts.
  const edges = useScrollEdges();
  const bodyRef = useCallback(
    (node: HTMLDivElement | null) => {
      body.current = node;
      edges(node);
    },
    [edges],
  );
  // Once: then it is done, so the palette or another pane opening Session Info again does not jump
  // back to this section.
  // The section lights for a moment (sessionInfo.css `[data-revealed]`), so a reveal of a section already
  // in view still shows it answered (the header's Environment line, Leo 2026-10-21: no dead clicks).
  // Not the reveal effect's cleanup: `onRevealed` clears the reveal at once, which would put it out.
  const lit = useRef<{ section: HTMLElement; timer: number }>(undefined);
  const unlight = useCallback(() => {
    if (!lit.current) return;
    window.clearTimeout(lit.current.timer);
    delete lit.current.section.dataset.revealed;
    lit.current = undefined;
  }, []);
  useEffect(() => unlight, [unlight]);
  const light = useCallback(
    (id: SessionInfoSectionId) => {
      const section = body.current?.querySelector<HTMLElement>(`[data-section="${id}"]`);
      section?.scrollIntoView?.({ block: "nearest" });
      if (!section) return;
      unlight();
      section.dataset.revealed = "";
      lit.current = { section, timer: window.setTimeout(unlight, REVEAL_LIT_MS) };
    },
    [unlight],
  );
  useEffect(() => {
    if (!revealed) return;
    // A section behind Show more: Show more opens first, and the reveal lights it once drawn.
    if (compactLook === "more" && !showMore && tuckedSections([revealed.section], sectionOrder()).length > 0) {
      setMore(true);
      return;
    }
    light(revealed.section);
    onRevealed?.();
  }, [revealed, onRevealed, light, compactLook, showMore, setMore]);
  // Usage's Show: Subagents opens, comes into view and lights, as a reveal does.
  const showSubagents = useCallback(() => {
    (onSection ?? setSessionInfoSection)("subagents", true);
    light("subagents");
  }, [onSection, light]);
  // The panel shows: Usage's numbers are read now, not left at whatever the list last carried.
  useEffect(() => onShowUsage?.(), [onShowUsage]);
  const anyUsage = useMemo(() => !!usageSessions?.some((entry) => entry.usageStats), [usageSessions]);
  const scheduled = made?.scheduled ?? [];
  const pullRequests = visibleChanges(made?.pullRequests ?? [], statuses);
  const sources = made?.sources ?? [];
  const folders = summary?.additionalDirectories ?? NO_FOLDERS;
  // What the chat made for the person (chatOutputs.ts): the documents its replies link to and the
  // deliverables its file tools created, never its code edits (the Changes row has those).
  const cwd = summary?.cwd;
  const madeFiles = useMemo(() => outputFiles ?? chatOutputs(rows, cwd), [outputFiles, rows, cwd]);
  // A file made and then deleted drops off, as the host answers for it (only on this Mac: another
  // machine's files are asked about nowhere).
  const missing = useMissingPaths(
    useMemo(() => (local ? madeFiles.map((output) => output.path) : []), [local, madeFiles]),
  );
  const outputs = useMemo(
    () => (missing.size === 0 ? madeFiles : madeFiles.filter((output) => !missing.has(output.path))),
    [madeFiles, missing],
  );
  const mcp = summary?.mcpServers ?? [];
  const connectorSummary = summarizeConnectors(mcp);
  const runningTasks = commands.filter((command) => command.state === "running").length;
  // Subagents shows only for a chat that has subagents or started chats: one that never used them
  // shows nothing.
  const limits = summary?.subsessionLimits;
  const chatId = summary?.sessionId;
  const appPanels = useAppPanelSections(
    chatId
      ? { session_id: chatId, cwd: summary?.cwd ?? "", branch: summary?.branch, harness: summary?.harness }
      : undefined,
  );
  const [appOpen, setAppOpen] = useState<Record<string, boolean>>({});
  const appNodes = Object.fromEntries(
    appPanels.map((section) => [
      section.id,
      <AppPanelSection
        key={section.id}
        section={section}
        open={appOpen[section.id] ?? true}
        onOpenChange={(open) => setAppOpen((current) => ({ ...current, [section.id]: open }))}
      />,
    ]),
  );
  // A chat on another machine: its sub-sessions live on that machine's acpmux, which takes the
  // limit only from its own person, so the line only reads.
  const setRunningLimit =
    onSetRunningLimit && chatId && !summary?.peer
      ? (maxRunning: number | null, from?: number) => onSetRunningLimit(chatId, maxRunning, from)
      : undefined;
  const progress = !known && agent ? subagentProgress(t, language, agent) : [];
  const value = (text: string) => <span className="acpmux-session-info-section__value">{text}</span>;
  const glance = layout === "glance";
  const environment = (
    <SessionInfoSection
      id="environment"
      title={t("rail.environment")}
      open={glance || state.environment}
      onOpenChange={fold("environment")}
      bare={glance}
    >
      <EnvironmentSection
        summary={summary}
        machineName={machineName}
        peerKinds={peerKinds}
        place={place}
        repository={repository}
        cloudRepositoryAvailable={cloudRepositoryAvailable}
        remoteControl={remoteControl}
        // No grant rows: Revoke Granted Access in the chat menu lists them (Lucas, 2026-11-05: ChatGPT's
        // panel has none, and "Trusted this chat's private folder" read as noise).
        onSave={onSaveEnvironment}
        onOpenFolder={onOpenFolder}
        edits={edits}
        onOpenChanges={onOpenChanges}
        projectLook={projectRowLook}
        remoteControlIcon={remoteControlIcon}
      />
    </SessionInfoSection>
  );
  // Context is one line, the window's share on a meter and its tokens used of its size; a click unfolds
  // its breakdown from Messages down (Lucas, 2026-11-06: "clicking on context should no longer open the
  // context modal. instead it will just expand"). The composer's context card's Details opens Session
  // Info on it, unfolded and lit (App.tsx `onOpenContext`, as main has it).
  const contextTokens = new Intl.NumberFormat(language, { notation: "compact", maximumFractionDigits: 1 });
  const context = known ? (
    <SessionInfoSection
      id="context"
      title={t("rail.context")}
      open={state.context}
      onOpenChange={fold("context")}
      meta={
        <>
          <span className="acpmux-session-info-meter" aria-hidden="true">
            <span style={{ width: `${percent}%` }} />
          </span>
          {value(`${contextTokens.format(usage.used)} / ${contextTokens.format(usage.size)}`)}
        </>
      }
    >
      <ContextSection
        usage={usage}
        percent={percent}
        breakdown={summary?.contextBreakdown}
        rowsOnly
        onViewPrompt={onViewPrompt}
      />
    </SessionInfoSection>
  ) : (
    progress.length > 0 && (
      <SessionInfoSection id="context" title={t("rail.context")} open meta={value(progress.join(" · "))} />
    )
  );
  // Usage and Connectors always show in the chat's own panel, folded, so the list under the Show more
  // line reads the same in every chat (Lucas, 2026-11-05). With nothing to list, one plain line: None.
  const hasConnectors = mcp.length > 0 || !!imessage;
  const connectors = (hasConnectors || !agent) && (
    <SessionInfoSection
      id="connectors"
      title={t("rail.connectors")}
      open={hasConnectors && state.connectors}
      onOpenChange={hasConnectors ? fold("connectors") : undefined}
      // This count describes the attached harness inventory. A loaded MCP server is not proof
      // of provider authentication or authorization, so never present it as a green connected count.
      meta={value(
        !hasConnectors
          ? t("sessionInfo.none")
          : mcp.length === 0 && imessage
            ? imessage.data.status === "connected"
              ? t("rail.connected", { count: 1 })
              : t("imessage.connect")
            : connectorSummary.kind === "reconnect"
              ? t("sessionInfo.connectors.reconnect", { count: connectorSummary.count })
              : connectorSummary.kind === "connecting"
                ? t("sessionInfo.connectors.connecting", { count: connectorSummary.count })
                : t("sessionInfo.connectors.loaded", { count: connectorSummary.count }),
      )}
    >
      <ConnectorsSection servers={mcp} onReconnect={onReconnectMcp} imessage={imessage} />
    </SessionInfoSection>
  );
  const changes = pullRequests.length > 0 && (
    <SessionInfoSection
      id="changes"
      title={t("header.changes")}
      open={state.changes}
      onOpenChange={fold("changes")}
      meta={pullRequests.length > 0 ? value(String(pullRequests.length)) : undefined}
    >
      {pullRequests.length > 0 && (
        <ChangesSection pullRequests={pullRequests} statuses={statuses} onOpenBeside={onOpenUrl} />
      )}
    </SessionInfoSection>
  );
  const sourcesSection = sources.length + folders.length > 0 && (
    <SessionInfoSection
      id="sources"
      title={t("summary.sources")}
      open={state.sources}
      onOpenChange={fold("sources")}
      meta={value(String(sources.length + folders.length))}
    >
      <SourcesSection
        sources={sources}
        folders={folders}
        cwd={summary?.cwd}
        onOpenFile={onOpenSourceFile}
        onOpenBeside={onOpenUrl}
        onOpenImage={onOpenImage}
        readImage={readPromptImage}
        expanded={sessionInfoState.sourcesAll}
        onExpandedChange={setSessionInfoSourcesAll}
      />
    </SessionInfoSection>
  );
  // The rows Outputs lists (OutputsSection): its documents, the gallery's one row and its files.
  const outputCount =
    outputs.length + (onOpenDocument ? documents.length : 0) + (artifacts > 0 && rows.length > 0 ? 1 : 0);
  const outputsShown = outputs.length + artifacts + (onOpenDocument ? documents.length : 0) > 0;
  const outputsSection = outputsShown && (
    <SessionInfoSection
      id="outputs"
      title={t("rail.outputs")}
      open={state.outputs}
      onOpenChange={fold("outputs")}
      meta={outputCount > 0 ? value(String(outputCount)) : undefined}
    >
      <OutputsSection
        files={outputs}
        artifacts={artifacts}
        documents={documents}
        onOpenDocument={onOpenDocument}
        // Opens as the reply's path chip opens it (chips/LinkChips.tsx): through the host, which checks
        // the path; a chat on another machine has its files there, so they only read.
        onOpenFile={local ? (onOpenOutputFile ?? ((path) => void openOutputFile(path))) : undefined}
        onOpenArtifacts={rows.length > 0 ? () => setGallery(true) : undefined}
      />
    </SessionInfoSection>
  );
  // The agent's plan, live: its steps done of its steps, on Context's meter.
  const planSteps = plan?.entries.length ?? 0;
  const stepsDone = plan ? planDone(plan) : 0;
  const progressSection = plan && planSteps > 0 && (
    <SessionInfoSection
      id="progress"
      title={t("sessionInfo.progress")}
      open={state.progress ?? true}
      onOpenChange={fold("progress")}
      meta={
        <>
          {value(t("sessionInfo.progress.count", { done: stepsDone, total: planSteps }))}
          <span className="acpmux-session-info-meter" aria-hidden="true">
            <span style={{ width: `${Math.round((stepsDone / planSteps) * 100)}%` }} />
          </span>
        </>
      }
    >
      <ProgressSection plan={plan} />
    </SessionInfoSection>
  );
  // A workflow Background tasks lists (Labs) is not a Subagents row too.
  const workflowIds = new Set(workflows.map((workflow) => workflow.id));
  const listedAgents = workflowIds.size > 0 ? agents.filter((agent) => !workflowIds.has(agent.id)) : agents;
  // The running limit's line ("Started chats: 2 of 16 at once") shows only while started chats run or
  // wait for a slot: it counts started chats, not subagents, so beside subagents alone it read as
  // theirs (Lucas, 2026-11-05, Session Info lab: "we should hide it by default then").
  const limitInUse = sessions.some((child) => child.waitsForSlot || sessionStatus(child) === "running");
  const subagentsSection = listedAgents.length + sessions.length > 0 && (
    <SessionInfoSection
      id="subagents"
      title={t("summary.subagents")}
      open={state.subagents}
      onOpenChange={fold("subagents")}
      meta={<SubagentCountsMeta agents={listedAgents} waiting={waiting} sessions={sessions} />}
    >
      {limitInUse && (
        <SubagentLimitStepper chatId={chatId} limits={limits} sessions={sessions} onSet={setRunningLimit} />
      )}
      {listedAgents.length + sessions.length > 0 && (
        <SubagentsSection
          agents={listedAgents}
          waiting={waiting}
          onOpen={onOpenSubagent}
          sessions={sessions}
          onOpenSession={onOpenSession}
          harness={summary?.harness}
        />
      )}
    </SessionInfoSection>
  );
  // The dev servers are background commands too: their rows head the one Background tasks section
  // (they were a card of their own, most often one row). Every server runs.
  const running = runningTasks + servers.length + workflows.filter((workflow) => workflow.state === "running").length;
  // A command a workflow's agent started is listed under that agent, not as the chat's own.
  const { own: ownCommands, workflows: workflowCommands } = attributeCommands(commands, workflows);
  // The other chats in this chat's worktree or on its branch (alsoHere.ts), shown only when there are.
  // A chat that goes a day idle leaves the list while Session Info stays open (useAlsoHere).
  const ownAlsoHere = useAlsoHere(chatId, shownAlsoHere ? undefined : allSessions);
  const alsoHereRows = shownAlsoHere ?? ownAlsoHere;
  const alsoHereSection = alsoHereRows.length > 0 && (
    <SessionInfoSection
      id="alsoHere"
      title={t("sessionInfo.alsoHere")}
      open={state.alsoHere}
      onOpenChange={fold("alsoHere")}
      meta={value(String(alsoHereRows.length))}
    >
      <AlsoHereSection rows={alsoHereRows} onOpen={onOpenChat} />
    </SessionInfoSection>
  );
  const tasks = servers.length + commands.length + scheduled.length + workflows.length > 0 && (
    <SessionInfoSection
      id="tasks"
      title={t("summary.backgroundTasks")}
      open={state.tasks}
      onOpenChange={fold("tasks")}
      meta={running > 0 ? value(t("rail.running", { count: running })) : undefined}
    >
      {workflows.length > 0 && (
        <WorkflowTasks
          workflows={workflows}
          commands={workflowCommands}
          onStopCommand={onStopProcess}
          onStop={onStopWorkflow}
          onOpenWorkflowAgent={onOpenWorkflowAgent}
          agentRowVariant={workflowAgentRowVariant}
        />
      )}
      {servers.length > 0 && <ServersSection servers={servers} onStop={onStopProcess} onOpenUrl={onOpenUrl} />}
      {ownCommands.length + scheduled.length > 0 && (
        <TasksSection
          commands={ownCommands}
          scheduled={scheduled}
          onStop={onStopProcess}
          local={local}
          calls={calls}
          onShowCall={onShowCall}
        />
      )}
    </SessionInfoSection>
  );
  // Usage shows once acpmux reports what this chat or any listed chat spends.
  const ownUsage = summary?.usageStats;
  const usageValue = usageMeta(t, ownUsage, language);
  const planLimits = typeof summary?.usageLimits === "object" ? summary.usageLimits : undefined;
  // acpmux reads a chat's spend from its harness records, so a new chat has none for a few minutes.
  const hasUsage = Boolean(ownUsage || anyUsage || planLimits);
  const usageSection = (hasUsage || !agent) && (
    <SessionInfoSection
      id="usage"
      title={t("sessionInfo.usage")}
      open={hasUsage && state.usage}
      onOpenChange={hasUsage ? fold("usage") : undefined}
      // No number of its own while another chat reports some: no value rather than a made-up one.
      meta={hasUsage ? usageValue && value(usageValue) : value(t("sessionInfo.none"))}
    >
      <UsageSection
        own={ownUsage}
        planLimits={planLimits}
        sessions={usageSessions ?? []}
        chatId={chatId}
        onOpen={onOpenChat}
        onCompact={onCompact}
        onShowSubagents={subagentsSection ? showSubagents : undefined}
        locale={language}
        ownRowLayout={usageOwnRowLayout}
        cacheLayout={usageCacheLayout}
      />
    </SessionInfoSection>
  );
  return (
    <div ref={bodyRef} className="acpmux-session-info__body" data-layout={layout}>
      {banner}
      {/* Where it runs, what it made, what it runs: one order the person drags (SessionInfoGroup.tsx). */}
      <SessionInfoSectionList
        look={compactLook}
        more={compactLook !== "more" || showMore}
        onMoreChange={compactLook === "more" ? setMore : undefined}
        sections={{
          environment,
          context,
          usage: usageSection,
          connectors,
          changes,
          sources: sourcesSection,
          outputs: outputsSection,
          progress: progressSection,
          subagents: subagentsSection,
          tasks,
          alsoHere: alsoHereSection,
          ...appNodes,
        }}
      />
      {gallery && (
        <GalleryDialog
          rows={rows}
          onClose={() => setGallery(false)}
          onOpenImage={
            onOpenImage &&
            ((src, alt, path) => {
              setGallery(false);
              onOpenImage(src, alt, path);
            })
          }
        />
      )}
    </div>
  );
}
