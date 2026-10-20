import React, { useEffect, useMemo, useRef, useState } from "react";
import { flushSync } from "react-dom";
import { useEscapeCloses } from "../../../ui/escapeDismiss";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import type { AcpmuxRow } from "../model";
import { subagentsIn } from "../subagents/subagentRows";
import { GalleryDialog } from "./GalleryDialog";
import { chatGallery } from "./chatGallery";
import { useScrollEdges } from "./scrollEdges";
import { sessionSummary } from "./sessionSummary";
import { SubagentStatusList, subagentStatus, waitingSubagents } from "./SubagentStatusList";
import { SubagentsTab } from "./SubagentsTab";
import { SummaryBody, type SummaryChanges } from "./SummaryBody";
import type { SummaryCardControl } from "./cardState";

/// What the chat has produced so far. A wide pane reserves a quiet right column; a narrow pane
/// uses a popover that dismisses on outside click or Escape. Folded popovers keep their header line,
/// with the subagents' live counts. The summary is read from the transcript only while the card is
/// open, so a live turn pays nothing for it otherwise.
/// A subagent row shows that subagent (`subagents.onOpen`). The Subagents section's title opens a
/// Subagents tab beside the Summary (SubagentsTab.tsx), as the ChatGPT desktop app's right pane
/// does; its close button goes back to the summary.
export function SummaryCard({
  card,
  rows,
  onOpenOutput,
  onOpenImage,
  changes,
  onOpenChanges,
  subagents,
}: {
  card: SummaryCardControl;
  rows: readonly AcpmuxRow[];
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
}) {
  const t = useT();
  const [gallery, setGallery] = useState(false);
  /// The Subagents tab: absent until the Subagents title opens it, then shown or behind Summary.
  const [tab, setTab] = useState<"summary" | "subagents" | undefined>(undefined);
  const shown = card.shown;
  const open = shown && !card.collapsed;
  const views = subagents.views;
  const agents = useMemo(() => (shown ? [...subagentsIn(rows, views).values()] : []), [shown, rows, views]);
  const asks = subagents.asks;
  const waiting = useMemo(() => (shown ? waitingSubagents(asks, views) : new Set<string>()), [shown, asks, views]);
  const galleryRow = useRef<HTMLElement | null>(null);
  const summary = useMemo(() => (open ? sessionSummary(rows) : undefined), [open, rows]);
  const galleryCount = useMemo(() => (open ? chatGallery(rows).length : 0), [open, rows]);
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
      if (target.closest(".acpmux-summary-button, .acpmux-chat-gallery")) return;
      close();
    };
    document.addEventListener("pointerdown", away, true);
    return () => document.removeEventListener("pointerdown", away, true);
  }, [close, popover]);
  useEscapeCloses(popover && !gallery, () => {
    const button = panel.current?.closest(".acpmux-stage")?.querySelector<HTMLElement>(".acpmux-summary-button");
    card.close();
    button?.focus();
  });
  if (!shown) {
    // Keep the inline column's width stable before the first summary row arrives. The rail is
    // intentionally invisible until it has content, but removing it from the flex row would make
    // the composer jump sideways when the first subagent or tool result is received.
    return card.reserve ? (
      <aside className="acpmux-summary-card acpmux-summary-card--reserve" aria-hidden="true" data-placement="inline" />
    ) : null;
  }
  const count = (status: string) => agents.filter((agent) => subagentStatus(agent, waiting) === status).length;
  const counts = [
    count("waiting") > 0 && t("summary.subagents.waiting", { n: count("waiting") }),
    count("running") > 0 && t("summary.subagents.running", { n: count("running") }),
    count("failed") > 0 && t("summary.subagents.failed", { n: count("failed") }),
    count("done") > 0 && t("summary.subagents.done", { n: count("done") }),
  ].filter(Boolean);
  const title = t("summary.open");
  const foldLabel = card.collapsed ? t("summary.expand") : t("summary.collapse");
  const onSubagents = tab === "subagents";
  return (
    <>
      <aside
        ref={panel}
        className="acpmux-summary-card"
        // Focusable from script only: the last place closing the Subagents tab can leave focus.
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
              title={foldLabel}
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
                  title={t("summary.subagents.closeTab")}
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
              /* tooltip-allow: the button shows the card title; the tooltip names what a click does */
              title={foldLabel}
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
              title={t("summary.close")}
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
            {/* The subagents first: they are what the card follows while a turn runs. */}
            {agents.length > 0 && (
              <SubagentStatusList
                agents={agents}
                waiting={waiting}
                current={subagents.current}
                onOpen={subagents.onOpen}
                autoOpen={subagents.autoOpen}
                onShowAll={() => setTab("subagents")}
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
              subagents={agents.length > 0 ? <></> : undefined}
              onOpenOutput={onOpenOutput}
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
