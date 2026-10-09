import React, { useLayoutEffect, useMemo, useRef } from "react";
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
  onOpenOutput?: (path: string) => void;
  onOpenChanges?: () => void;
  onAddSource?: () => void;
  onOpenGallery?: () => void;
  onFollow?: () => void;
  /// The pin control: pins the card (popover) or unpins it (card). Unset in a narrow pane.
  pin?: { pinned: boolean; onToggle(): void };
  /// The popover focuses its first enabled row on open; the pinned card never takes focus.
  focusFirstRow?: boolean;
};

/// The chat summary's content, the same in the header popover and the pinned card (PINNED-SUMMARY
/// P2-P6): the project with the pin control and the sections menu, the Changes row, the plan,
/// the built-in sections and the custom ones (S1). The menu hides and shows each section.
export function SummaryPanel({
  summary,
  project,
  folder,
  sections = [],
  galleryCount,
  onOpenOutput,
  onOpenChanges,
  onAddSource,
  onOpenGallery,
  onFollow,
  pin,
  focusFirstRow = false,
}: SummaryPanelProps) {
  const t = useT();
  const top = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    if (!focusFirstRow) return;
    const scope = top.current?.parentElement;
    scope?.querySelector<HTMLElement>(".acpmux-summary-link:not(:disabled), a[href]")?.focus();
  }, [focusFirstRow]);
  const [hidden, setHidden] = useHiddenSections();
  const custom = useMemo(() => sections.map((section) => sanitizeSection(section, folder)), [sections, folder]);
  const additions = summary.outputs.reduce((sum, file) => sum + (file.additions ?? 0), 0);
  const deletions = summary.outputs.reduce((sum, file) => sum + (file.deletions ?? 0), 0);
  const menuItems = [
    ...BUILTIN_SECTIONS.map((id) => ({ id, title: t(`summary.${id}`) })),
    ...custom.map((section) => ({ id: section.id, title: section.title })),
  ];
  return (
    <>
      <div ref={top} className="flex h-8 items-center gap-1 pr-0.5 pl-2">
        <span className="min-w-0 flex-1 truncate text-[13px] text-muted" title={folder}>
          {project}
        </span>
        {pin && (
          <button
            type="button"
            data-summary-pin
            className="grid size-6 cursor-default place-items-center rounded-md border-0 bg-transparent p-0 text-muted hover:bg-hover hover:text-fg"
            aria-pressed={pin.pinned}
            aria-label={pin.pinned ? t("summary.unpin") : t("summary.pin")}
            title={pin.pinned ? t("summary.unpin") : t("summary.pin")}
            onClick={pin.onToggle}
          >
            <Icon name={pin.pinned ? "state.pinned" : "action.pin"} size={ROW_ICON} />
          </button>
        )}
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
            {summary.outputs.length > 0 && (
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
