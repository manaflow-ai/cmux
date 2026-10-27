import React, { useEffect, useMemo, useRef, useState } from "react";
import { flushSync } from "react-dom";
import { useEscapeCloses } from "../../../ui/escapeDismiss";
import { usePresence } from "../../../ui/presence";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import type { AcpmuxRow } from "../model";
import type { StartedSession } from "../started/startedSessions";
import { subagentsIn } from "../subagents/subagentRows";
import { GalleryDialog } from "./GalleryDialog";
import { chatGallery } from "./chatGallery";
import { useScrollEdges } from "./scrollEdges";
import { sessionSummary } from "./sessionSummary";
import type { SubsessionRow } from "../subagents/subsessions";
import { SUBSESSION_STATUS, SubagentStatusList, subagentStatus, waitingSubagents } from "./SubagentStatusList";
import { sessionStatus } from "../inspector/ChildSessionRows";
import { sessionRetry } from "../subagents/retryState";
import { SubagentsTab } from "./SubagentsTab";
import { SummaryBody, type SummaryChanges } from "./SummaryBody";
import type { ChatToolsControl } from "./SourcesAddMenu";
import type { SummaryCardControl } from "./cardState";
import { backgroundCommands } from "../inspector/processes";
import type { SummaryBackgroundTask } from "./sessionSummary";
import type { ProcessRegistry } from "../inspector/processes";
import type { WorkflowActions } from "./WorkflowSummary";
import type { WorkflowSummary } from "./workflow";
import type { WorkflowCapacitySignal } from "./foldWorkflows";

const NO_SESSIONS: readonly StartedSession[] = [];
const NO_TASKS: readonly SummaryBackgroundTask[] = [];
const NO_REGISTRY: ProcessRegistry = { processes: [], listed: false };

const NO_SUBSESSIONS: readonly SubsessionRow[] = [];

/// What the chat has produced so far. A wide pane reserves a quiet right column; a narrow pane
/// uses a popover that dismisses on outside click or Escape. Folded popovers keep their header line,
/// with the subagents' live counts. The summary is read from the transcript only while the card is
/// open, so a live turn pays nothing for it otherwise.
/// A subagent row shows that subagent (`subagents.onOpen`). The Subagents section's title opens a
/// Subagents tab beside the Summary (SubagentsTab.tsx), as the ChatGPT desktop app's right pane
/// does; its close button goes back to the summary.
/// Background work shows as compact task cards: the chat's background commands (`background`, the
/// process registry's merged with the transcript's, backgroundWork.ts) keep their description,
/// running/completed/failed state and Stop affordance, and the chats its agent started (`sessions`)
/// stay under Subagents. The header's counts include the running ones.
export function SummaryCard({
  card,
  rows,
  cwd,
  onOpenOutput,
  onOpenImage,
  changes,
  onOpenChanges,
  subagents,
  subsessions,
  onAttach,
  background,
  sessions,
  tools,
  workflow,
  workflowActions,
  workflows,
  workflowActionsFor,
  workflowCapacity,
}: {
  card: SummaryCardControl;
  rows: readonly AcpmuxRow[];
  cwd?: string;
  onOpenOutput?: (path: string) => void;
  onOpenImage?: (src: string, alt: string) => void;
  /// The last turn that edited files, with its counts and files; the Changes rows open its diff,
  /// or a file's.
  changes?: SummaryChanges;
  onOpenChanges?: (path?: string) => void;
  subagents: {
    /// The subagents' own views (the snapshot's `subagentViews`), for their nested subagents.
    views: Record<string, AcpmuxRow[]> | undefined;
    /// The subagent this pane shows, if any.
    current: string | undefined;
    /// The tool calls the chat's open asks are about (SubagentStatusList.tsx `pendingToolCalls`).
    asks: ReadonlySet<string>;
    onOpen: (id: string) => void;
    /// Whether new subagents open in panes of their own, and its switch; none where no pane opens.
    autoOpen?: { on: boolean; set: (on: boolean) => void };
  };
  /// The chat's sub-sessions (subagents/subsessions.ts `subsessionRows`), listed after its
  /// subagents, and how a row opens one's chat beside this one.
  subsessions?: { rows: readonly SubsessionRow[]; onOpen: (sessionId: string) => void };
  /// Sources' + (Attach files or folders), for a chat on this computer.
  onAttach?: () => void;
  /// The chat's background commands: the process registry's records, the transcript's tasks still
  /// running (for the folded header, which reads no summary), and Stop (`_acpmux/process/kill`).
  background?: ProcessRegistry & {
    running: readonly SummaryBackgroundTask[];
    onStop?: (processId: string) => Promise<unknown>;
  };
  /// The chats this chat's agent started, and how one opens.
  sessions?: { list: readonly StartedSession[]; onOpen: (sessionId: string) => void };
  /// Sources' Use tools: the chat's tools, where acpmux can change them (cx-thur3).
  tools?: ChatToolsControl;
  /// Labs-only workflow data from the optional acpmux adapter.
  workflow?: WorkflowSummary;
  workflowActions?: WorkflowActions;
  workflows?: readonly WorkflowSummary[];
  workflowActionsFor?: (workflow: WorkflowSummary) => WorkflowActions;
  workflowCapacity?: WorkflowCapacitySignal;
}) {
  const t = useT();
  const [gallery, setGallery] = useState(false);
  /// The Subagents tab: absent until the Subagents title opens it, then shown or behind Summary.
  const [tab, setTab] = useState<"summary" | "subagents" | undefined>(undefined);
  const shown = card.shown;
  // The card slides in from the pane's right edge and back out (ui/presence.ts): the inline column
  // travels its own width inside the pane, the popover a few points. It keeps its content while it
  // leaves; a second open while it is open changes nothing.
  const presence = usePresence(shown, "right");
  const drawn = presence.present;
  const open = drawn && !card.collapsed;
  const views = subagents.views;
  const agents = useMemo(() => (drawn ? [...subagentsIn(rows, views).values()] : []), [drawn, rows, views]);
  const asks = subagents.asks;
  const waiting = useMemo(() => (drawn ? waitingSubagents(asks, views) : new Set<string>()), [drawn, asks, views]);
  const galleryRow = useRef<HTMLElement | null>(null);
  const summary = useMemo(() => (open ? sessionSummary(rows, undefined, cwd) : undefined), [open, rows, cwd]);
  const galleryCount = useMemo(() => (open ? chatGallery(rows).length : 0), [open, rows]);
  const registry = background ?? NO_REGISTRY;
  const running = background?.running ?? NO_TASKS;
  // The open card merges the registry with every transcript task; a folded one, the running ones.
  const commands = useMemo(
    () => (shown ? backgroundCommands(registry.processes, summary?.backgroundTasks ?? running, registry.listed) : []),
    [shown, registry.processes, registry.listed, summary, running],
  );
  const panel = useRef<HTMLElement>(null);
  const popover = shown && !card.column;
  const edges = useScrollEdges();
  const close = card.close;
  // Closing the Subagents tab leaves focus on the Subagents title that opened it; on a folded
  // popover, where that title is not drawn, on the fold button, else on the card itself.
  const closeTab = () => {
    flushSync(() => setTab(undefined));
    const card = panel.current;
    (
      card?.querySelector<HTMLElement>(".acpmux-summary-title__button") ??
      card?.querySelector<HTMLElement>(".acpmux-summary-card__fold") ??
      card
    )?.focus();
  };
  // A tab picked on a folded popover opens it: the tab's content is what the click asks for.
  const showTab = (next: "summary" | "subagents") => {
    if (!card.column && card.collapsed) card.fold(false);
    setTab(next);
  };
  useEffect(() => {
    if (!popover) return;
    const away = (event: Event) => {
      const target = event.target instanceof Element ? event.target : null;
      if (!target || panel.current?.contains(target)) return;
      // The card's own menus (Sources' +, SourcesAddMenu.tsx) draw in the page's portal, outside it.
      if (target.closest(".acpmux-summary-button, .acpmux-chat-gallery, .acpmux-summary-menu")) return;
      close();
    };
    document.addEventListener("pointerdown", away, true);
    return () => document.removeEventListener("pointerdown", away, true);
  }, [close, popover]);
  // Escape in one of the card's menus closes that menu only.
  useEscapeCloses(
    popover && !gallery,
    () => {
      const button = panel.current?.closest(".acpmux-stage")?.querySelector<HTMLElement>(".acpmux-summary-button");
      card.close();
      button?.focus();
    },
    ".acpmux-summary-menu",
  );
  if (!drawn) {
    // Keep the inline column's width stable before the first summary row arrives. The rail is
    // intentionally invisible until it has content, but removing it from the flex row would make
    // the composer jump sideways when the first subagent or tool result is received.
    return card.reserve ? (
      <aside className="acpmux-summary-card acpmux-summary-card--reserve" aria-hidden="true" data-placement="inline" />
    ) : null;
  }
  const subsessionRows = subsessions?.rows ?? NO_SUBSESSIONS;
  // A started chat that is also a sub-session shows once, as its sub-session row.
  const children = (sessions?.list ?? NO_SESSIONS).filter(
    (child) => !subsessionRows.some((row) => row.sessionId === child.sessionId),
  );
  const count = (status: string) =>
    agents.filter((agent) => subagentStatus(agent, waiting) === status).length +
    subsessionRows.filter(
      (session) =>
        (sessionRetry(session).kind === "retrying" ? SUBSESSION_STATUS.working : SUBSESSION_STATUS[session.state]) ===
        status,
    ).length;
  // A started chat waiting on the person is counted with the waiting subagents.
  const waitingCount = count("waiting") + children.filter((child) => sessionStatus(child) === "waiting").length;
  const runningCommands = commands.filter((command) => command.state === "running").length;
  // A started chat whose turn runs is a running subagent too: one word, as the tray says.
  const runningCount = count("running") + children.filter((child) => sessionStatus(child) === "running").length;
  const counts = [
    waitingCount > 0 && t("summary.subagents.waiting", { n: waitingCount }),
    runningCount > 0 && t("summary.subagents.running", { n: runningCount }),
    runningCommands > 0 && t("turn.working.commands", { n: runningCommands }),
    count("failed") > 0 && t("summary.subagents.failed", { n: count("failed") }),
    count("stopped") > 0 && t("summary.subagents.stopped", { n: count("stopped") }),
    count("done") > 0 && t("summary.subagents.done", { n: count("done") }),
  ].filter(Boolean);
  const title = t("summary.open");
  const foldLabel = card.collapsed ? t("summary.expand") : t("summary.collapse");
  const onSubagents = tab === "subagents";
  const hasSubagents = agents.length > 0 || children.length > 0 || subsessionRows.length > 0;
  return (
    <>
      <aside
        {...presence.props}
        ref={(node) => {
          panel.current = node;
          presence.props.ref(node);
        }}
        className="acpmux-summary-card"
        inert={presence.leaving}
        // ui-allow: focusable from script only, the last place closing the Subagents tab can leave focus.
        tabIndex={-1}
        aria-label={title}
        data-placement={card.column ? "inline" : "popover"}
        data-collapsed={!card.column && card.collapsed ? "" : undefined}
      >
        <div className="acpmux-summary-card__head">
          {tab && !card.column && (
            // The popover keeps its fold control beside the tabs, so a narrow pane can still fold it.
            <button
              type="button"
              className="acpmux-summary-card__fold acpmux-summary-card__fold--icon"
              aria-expanded={!card.collapsed}
              aria-label={foldLabel}
              onClick={() => card.fold(!card.collapsed)}
            >
              <Icon name={card.collapsed ? "disclosure.collapsed" : "disclosure.expanded"} size={10} />
            </button>
          )}
          {tab ? (
            // Toggle buttons (aria-pressed), as the gallery's filters are: page code carries no raw roles.
            <div className="acpmux-summary-tabs">
              <button
                type="button"
                className="acpmux-summary-tab"
                aria-pressed={!onSubagents}
                data-selected={onSubagents ? undefined : ""}
                onClick={() => showTab("summary")}
              >
                {t("summary.title")}
              </button>
              <span className="acpmux-summary-tab" data-closable="" data-selected={onSubagents ? "" : undefined}>
                <button
                  type="button"
                  className="acpmux-summary-tab__label"
                  aria-pressed={onSubagents}
                  onClick={() => showTab("subagents")}
                >
                  {t("summary.subagents")}
                </button>
                <button
                  type="button"
                  className="acpmux-summary-tab__close"
                  aria-label={t("summary.subagents.closeTab")}
                  onClick={closeTab}
                >
                  <Icon name="action.close" size={10} />
                </button>
              </span>
            </div>
          ) : card.column ? (
            <span className="acpmux-summary-card__title">{t("summary.title")}</span>
          ) : (
            <button
              type="button"
              className="acpmux-summary-card__fold"
              aria-expanded={!card.collapsed}
              onClick={() => card.fold(!card.collapsed)}
            >
              <Icon name={card.collapsed ? "disclosure.collapsed" : "disclosure.expanded"} size={10} />
              <span className="acpmux-summary-card__title">{t("summary.title")}</span>
              {counts.length > 0 && <span className="acpmux-summary-card__counts">{counts.join(" · ")}</span>}
            </button>
          )}
          {!tab && card.column && counts.length > 0 && (
            <span className="acpmux-summary-card__counts">{counts.join(" · ")}</span>
          )}
          {!card.column && (
            <button
              type="button"
              className="acpmux-summary-card__close"
              aria-label={t("summary.close")}
              onClick={(event) => {
                // The button goes with the card: focus moves to the header's summary button.
                const pane = event.currentTarget.closest(".acpmux-stage");
                card.close();
                pane?.querySelector<HTMLElement>(".acpmux-summary-button")?.focus();
              }}
            >
              <Icon name="action.close" size={12} />
            </button>
          )}
        </div>
        {open && onSubagents && (
          <div className="acpmux-summary-card__body" ref={edges}>
            <SubagentsTab agents={agents} waiting={waiting} onOpen={subagents.onOpen} />
          </div>
        )}
        {summary && !onSubagents && (
          <div className="acpmux-summary-card__body" ref={edges}>
            {/* The subagents, sub-sessions and started chats first: they are what the card follows while a turn runs. */}
            {hasSubagents && (
              <SubagentStatusList
                agents={agents}
                waiting={waiting}
                current={subagents.current}
                onOpen={subagents.onOpen}
                autoOpen={agents.length > 0 ? subagents.autoOpen : undefined}
                // The tab lists subagents only; a chat with only sub-sessions or started chats has none to show there.
                onShowAll={agents.length > 0 ? () => setTab("subagents") : undefined}
                subsessions={subsessionRows}
                sessions={children}
                onOpenSession={sessions?.onOpen ?? subsessions?.onOpen}
                stack={agents.length === 0 ? summary.subagents : undefined}
              />
            )}
            <SummaryBody
              summary={summary}
              galleryCount={galleryCount}
              onOpenGallery={() => {
                galleryRow.current = document.activeElement instanceof HTMLElement ? document.activeElement : null;
                setGallery(true);
              }}
              changes={changes}
              onOpenChanges={onOpenChanges}
              subagents={hasSubagents ? <></> : undefined}
              onOpenOutput={onOpenOutput}
              onAttach={onAttach}
              tools={tools}
              commands={commands}
              onStopCommand={background?.onStop}
              workflow={workflow}
              workflowActions={workflowActions}
              workflows={workflows}
              workflowActionsFor={workflowActionsFor}
              workflowCapacity={workflowCapacity}
            />
          </div>
        )}
      </aside>
      {/* Outside the card: the card's animation transform would hold the gallery's fixed box. */}
      {gallery && (
        <GalleryDialog
          rows={rows}
          onClose={() => {
            setGallery(false);
            // Back to the Outputs row that opened it (not when the image viewer takes its place).
            queueMicrotask(() => galleryRow.current?.focus());
          }}
          onOpenImage={
            onOpenImage &&
            ((src, alt) => {
              setGallery(false);
              onOpenImage(src, alt);
            })
          }
        />
      )}
    </>
  );
}
