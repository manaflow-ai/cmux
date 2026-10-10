import React, { useMemo } from "react";
import { Menu, MenuButton, MenuCheckboxItem, MenuPopup } from "../../../ui/Menu";
import { Counts } from "../changes/Counts";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { rowIconSize } from "../icons/iconSize";
import { CustomSection } from "./CustomSection";
import { useHiddenSections } from "./summaryPin";
import { BUILTIN_SECTIONS, SummaryPopover } from "./SummaryPopover";
import { sanitizeSection, type SummarySectionInput } from "./summaryRows";
import type { SessionSummary, SummaryPlanStep } from "./sessionSummary";
import { SummarySection } from "./SummarySection";

const ROW_ICON = rowIconSize(12);
const STEP_ICON: Record<SummaryPlanStep["status"], "task.status.done" | "task.status.started" | "task.status.todo"> = {
  completed: "task.status.done",
  in_progress: "task.status.started",
  pending: "task.status.todo",
};

export type SummaryPanelProps = {
  summary: SessionSummary;
  /// The chat's project name, over the sections.
  project?: string;
  /// The chat's folder: an agent row's path opens only inside it.
  folder?: string;
  sections?: readonly SummarySectionInput[];
  galleryCount?: number;
  /// The last turn that edited files, with its counts (App's lastChanges); without it the row sums the outputs.
  changes?: { additions: number; deletions: number };
  onOpenOutput?: (path: string) => void;
  onOpenChanges?: () => void;
  onAddSource?: () => void;
  onOpenGallery?: () => void;
  onFollow?: () => void;
  /// Closes the docked panel (its close button).
  onClose?: () => void;
};

/// The chat summary's content in the docked panel (PINNED-SUMMARY P1'-P6): the project with the sections menu
/// and the close button, the Changes row, the plan, the built-in sections and the custom ones (S1). The menu
/// hides and shows each section.
export function SummaryPanel({
  summary,
  project,
  folder,
  sections = [],
  galleryCount,
  changes,
  onOpenOutput,
  onOpenChanges,
  onAddSource,
  onOpenGallery,
  onFollow,
  onClose,
}: SummaryPanelProps) {
  const t = useT();
  const [hidden, setHidden] = useHiddenSections();
  const custom = useMemo(() => sections.map((section) => sanitizeSection(section, folder)), [sections, folder]);
  const additions = changes?.additions ?? summary.outputs.reduce((sum, file) => sum + (file.additions ?? 0), 0);
  const deletions = changes?.deletions ?? summary.outputs.reduce((sum, file) => sum + (file.deletions ?? 0), 0);
  const menuItems = [
    ...BUILTIN_SECTIONS.map((id) => ({ id, title: t(`summary.${id}`) })),
    ...custom.map((section) => ({ id: section.id, title: section.title })),
  ];
  return (
    <>
      <div className="flex h-8 items-center gap-1 pr-0.5 pl-2">
        <span className="min-w-0 flex-1 truncate text-body text-muted" title={folder}>
          {project}
        </span>
        <Menu>
          <MenuButton
            className="grid size-6 cursor-default place-items-center rounded-md border-0 bg-transparent p-0 text-muted hover:bg-hover hover:text-fg"
            label={t("summary.menu")}
          >
            <Icon name="action.more" size={ROW_ICON} />
          </MenuButton>
          <MenuPopup align="end">
            {menuItems.map((item) => (
              <MenuCheckboxItem
                key={item.id}
                checked={!hidden.has(item.id)}
                onCheckedChange={(checked) => setHidden(item.id, !checked)}
              >
                {item.title}
              </MenuCheckboxItem>
            ))}
          </MenuPopup>
        </Menu>
        {onClose && (
          <button
            type="button"
            data-summary-close
            className="grid size-6 cursor-default place-items-center rounded-md border-0 bg-transparent p-0 text-muted hover:bg-hover hover:text-fg"
            aria-label={t("summary.close")}
            title={t("summary.close")}
            onClick={onClose}
          >
            <Icon name="action.close" size={ROW_ICON} />
          </button>
        )}
      </div>
      <ul className="acpmux-summary-list">
        <li>
          <button
            type="button"
            data-summary-changes
            className="acpmux-summary-row acpmux-summary-link"
            disabled={!onOpenChanges}
            onClick={onOpenChanges}
          >
            <Icon name="diff.file" size={ROW_ICON} row />
            <span className="acpmux-summary-text">{t("summary.changes")}</span>
            {(summary.outputs.length > 0 || changes) && (
              <>
                <span className="acpmux-summary-meta">{summary.outputs.length}</span>
                <Counts additions={additions} deletions={deletions} />
              </>
            )}
          </button>
        </li>
      </ul>
      {summary.plan.length > 0 && !hidden.has("plan") && (
        <SummarySection
          id="plan"
          title={t("summary.plan")}
          items={summary.plan}
          row={(step) => (
            <li
              key={step.text}
              className={`acpmux-summary-row${step.status === "completed" ? " text-muted line-through" : ""}`}
            >
              <Icon name={STEP_ICON[step.status]} size={ROW_ICON} row />
              <span className="acpmux-summary-text" title={step.text}>
                {step.text}
              </span>
            </li>
          )}
        />
      )}
      <SummaryPopover
        summary={summary}
        galleryCount={galleryCount}
        onOpenOutput={onOpenOutput}
        onOpenGallery={onOpenGallery}
        onFollow={onFollow}
        onAddSource={onAddSource}
        hidden={hidden}
      />
      {custom
        .filter((section) => !hidden.has(section.id))
        .map((section) => (
          <CustomSection key={section.id} section={section} onOpenOutput={onOpenOutput} onFollow={onFollow} />
        ))}
    </>
  );
}
