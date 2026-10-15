import React, { useEffect, useMemo, useRef, useState } from "react";
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

/// What the chat has produced so far: a card pinned under the header's summary button (cardState.ts
/// says how it sits beside or over the chat). A press elsewhere never closes it; its close button,
/// the header's summary button and Escape do. Its head counts the subagents live. Its
/// first row opens a new terminal or a new browser beside the chat, as the chat menu's New terminal
/// and New browser do (`actions`). The summary is read from the transcript only while it shows, so a live turn
/// pays nothing for it otherwise. A subagent row shows that subagent (`subagents.onOpen`). The
/// Subagents section's title opens a Subagents tab beside the Summary (SubagentsTab.tsx), as the
/// ChatGPT desktop app's right pane does; its close button goes back to the summary.
export function SummaryCard({
  card,
  rows,
  onOpenOutput,
  onOpenImage,
  changes,
  onOpenChanges,
  subagents,
  actions,
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
  /// New terminal and New browser beside the chat; none where the pane opens no split.
  actions?: { terminal?: () => void; browser?: () => void };
}) {
  const t = useT();
  const [gallery, setGallery] = useState(false);
  /// The Subagents tab: absent until the Subagents title opens it, then shown or behind Summary.
  const [tab, setTab] = useState<"summary" | "subagents" | undefined>(undefined);
  const shown = card.shown;
  const views = subagents.views;
  const agents = useMemo(() => (shown ? [...subagentsIn(rows, views).values()] : []), [shown, rows, views]);
  const asks = subagents.asks;
  const waiting = useMemo(() => (shown ? waitingSubagents(asks, views) : new Set<string>()), [shown, asks, views]);
  const galleryRow = useRef<HTMLElement | null>(null);
  const summary = useMemo(() => (shown ? sessionSummary(rows) : undefined), [shown, rows]);
  const galleryCount = useMemo(() => (shown ? chatGallery(rows).length : 0), [shown, rows]);
  const panel = useRef<HTMLElement>(null);
  const edges = useScrollEdges();
  const close = card.close;
  // Closing the Subagents tab leaves focus on the Subagents title that opened it.
  const refocus = useRef(false);
  useEffect(() => {
    if (tab || !refocus.current) return;
    refocus.current = false;
    panel.current?.querySelector<HTMLElement>(".acpmux-summary-title__button")?.focus();
  }, [tab]);
  // Escape closes it (the gallery's own Escape first). Focus in the card goes to the header's
  // button; focus elsewhere (the composer) stays where it is.
  useEscapeCloses(shown && !gallery, () => {
    const inside = panel.current?.contains(document.activeElement) ?? false;
    const button = panel.current?.closest(".acpmux-stage")?.querySelector<HTMLElement>(".acpmux-summary-button");
    close();
    if (inside) button?.focus();
  });
  if (!shown) return null;
  const count = (status: string) => agents.filter((agent) => subagentStatus(agent, waiting) === status).length;
  const counts = [
    count("waiting") > 0 && t("summary.subagents.waiting", { n: count("waiting") }),
    count("running") > 0 && t("summary.subagents.running", { n: count("running") }),
    count("failed") > 0 && t("summary.subagents.failed", { n: count("failed") }),
    count("done") > 0 && t("summary.subagents.done", { n: count("done") }),
  ].filter(Boolean);
  const title = t("summary.open");
  const onSubagents = tab === "subagents";
  return (
    <>
      <aside
        ref={panel}
        id={card.id}
        className="acpmux-summary-card"
        aria-label={title}
        data-placement={card.push ? "push" : "over"}
      >
        <div className="acpmux-summary-card__head">
          {tab ? (
            // Toggle buttons (aria-pressed), as the gallery's filters are: page code carries no raw roles.
            <div className="acpmux-summary-tabs">
              <button
                type="button"
                className="acpmux-summary-tab"
                aria-pressed={!onSubagents}
                data-selected={onSubagents ? undefined : ""}
                onClick={() => setTab("summary")}
              >
                {t("summary.title")}
              </button>
              <span className="acpmux-summary-tab" data-closable="" data-selected={onSubagents ? "" : undefined}>
                <button
                  type="button"
                  className="acpmux-summary-tab__label"
                  aria-pressed={onSubagents}
                  onClick={() => setTab("subagents")}
                >
                  {t("summary.subagents")}
                </button>
                <button
                  type="button"
                  className="acpmux-summary-tab__close"
                  aria-label={t("summary.subagents.closeTab")}
                  title={t("summary.subagents.closeTab")}
                  onClick={() => {
                    refocus.current = true;
                    setTab(undefined);
                  }}
                >
                  <Icon name="action.close" size={10} />
                </button>
              </span>
            </div>
          ) : (
            <span className="acpmux-summary-card__title">{t("summary.title")}</span>
          )}
          {counts.length > 0 && <span className="acpmux-summary-card__counts">{counts.join(" · ")}</span>}
          <button
            type="button"
            className="acpmux-summary-card__close"
            aria-label={t("summary.close")}
            title={t("summary.close")}
            onClick={(event) => {
              // The button goes with the panel: focus moves to the header's summary button.
              const pane = event.currentTarget.closest(".acpmux-shell");
              card.close();
              pane?.querySelector<HTMLElement>(".acpmux-summary-button")?.focus();
            }}
          >
            <Icon name="action.close" size={12} />
          </button>
        </div>
        {onSubagents && (
          <div className="acpmux-summary-card__body" ref={edges}>
            <SubagentsTab agents={agents} waiting={waiting} onOpen={subagents.onOpen} />
          </div>
        )}
        {summary && !onSubagents && (
          <div className="acpmux-summary-card__body" ref={edges}>
            {(actions?.terminal || actions?.browser) && (
              <div className="acpmux-summary-actions">
                {actions.terminal && (
                  <button type="button" className="acpmux-summary-action" onClick={actions.terminal}>
                    <Icon name="terminal" size={14} />
                    <span>{t("chatMenu.newTerminal")}</span>
                  </button>
                )}
                {actions.browser && (
                  <button type="button" className="acpmux-summary-action" onClick={actions.browser}>
                    <Icon name="browser" size={14} />
                    <span>{t("chatMenu.newBrowser")}</span>
                  </button>
                )}
              </div>
            )}
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
