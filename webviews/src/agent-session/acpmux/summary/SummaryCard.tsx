import React, { useMemo, useState } from "react";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import type { AcpmuxRow } from "../model";
import { subagentsIn } from "../subagents/subagentRows";
import { GalleryDialog } from "./GalleryDialog";
import { chatGallery } from "./chatGallery";
import { sessionSummary } from "./sessionSummary";
import { SubagentStatusList, subagentStatus, waitingSubagents } from "./SubagentStatusList";
import { SummaryBody, type SummaryChanges } from "./SummaryBody";
import type { SummaryCardControl } from "./cardState";

/// What the chat has produced so far, as a card at the pane's top right, over the transcript and
/// never over the composer. It is not a popover: a click elsewhere leaves it in place, and only its
/// own close button or the header's summary button hides it. Folded, it keeps its header line,
/// with the subagents' live counts. Its state is per chat (cardState.ts). The summary is read
/// from the transcript only while the card is open, so a live turn pays nothing for it otherwise.
/// A subagent row shows that subagent (`subagents.onOpen`).
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
    onOpen: (id: string) => void;
  };
}) {
  const t = useT();
  const [gallery, setGallery] = useState(false);
  const shown = card.shown;
  const open = shown && !card.collapsed;
  const views = subagents.views;
  const agents = useMemo(() => (shown ? [...subagentsIn(rows, views).values()] : []), [shown, rows, views]);
  const waiting = useMemo(() => (shown ? waitingSubagents(rows, views) : new Set<string>()), [shown, rows, views]);
  const summary = useMemo(() => (open ? sessionSummary(rows) : undefined), [open, rows]);
  const galleryCount = useMemo(() => (open ? chatGallery(rows).length : 0), [open, rows]);
  if (!shown) return null;
  const count = (status: string) => agents.filter((agent) => subagentStatus(agent, waiting) === status).length;
  const counts = [
    count("waiting") > 0 && t("summary.subagents.waiting", { n: count("waiting") }),
    count("running") > 0 && t("summary.subagents.running", { n: count("running") }),
    count("failed") > 0 && t("summary.subagents.failed", { n: count("failed") }),
    count("done") > 0 && t("summary.subagents.done", { n: count("done") }),
  ].filter(Boolean);
  const title = t("summary.open");
  const foldLabel = card.collapsed ? t("summary.expand") : t("summary.collapse");
  return (
    <>
      <aside className="acpmux-summary-card" aria-label={title} data-collapsed={card.collapsed || undefined}>
        <div className="acpmux-summary-card__head">
          <button
            type="button"
            className="acpmux-summary-card__fold"
            aria-expanded={!card.collapsed}
            aria-label={foldLabel}
            title={foldLabel}
            onClick={() => card.fold(!card.collapsed)}
          >
            <Icon name={card.collapsed ? "disclosure.collapsed" : "disclosure.expanded"} size={10} />
            <span className="acpmux-summary-card__title">{t("summary.title")}</span>
            {counts.length > 0 && <span className="acpmux-summary-card__counts">{counts.join(" · ")}</span>}
          </button>
          <button
            type="button"
            className="acpmux-summary-card__close"
            aria-label={t("summary.close")}
            title={t("summary.close")}
            onClick={card.close}
          >
            <Icon name="action.close" size={12} />
          </button>
        </div>
        {summary && (
          <div className="acpmux-summary-card__body">
            <SummaryBody
              summary={summary}
              galleryCount={galleryCount}
              onOpenGallery={() => setGallery(true)}
              changes={changes}
              onOpenChanges={onOpenChanges}
              subagents={
                agents.length > 0 ? (
                  <SubagentStatusList
                    agents={agents}
                    waiting={waiting}
                    current={subagents.current}
                    onOpen={subagents.onOpen}
                  />
                ) : undefined
              }
              onOpenOutput={onOpenOutput}
            />
          </div>
        )}
      </aside>
      {/* Outside the card: the card's animation transform would hold the gallery's fixed box. */}
      {gallery && (
        <GalleryDialog
          rows={rows}
          onClose={() => setGallery(false)}
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
