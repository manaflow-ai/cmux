import { useState, type DragEvent, type KeyboardEvent, type ReactNode } from "react";
import { useT } from "../i18n";
import type { InspectorOrderId } from "./sectionOrder";

type DragTarget = { id: InspectorOrderId; after: boolean } | undefined;

/// A separated Session Info card. The handle owns all reordering input, so pressing a section's
/// disclosure still only folds it; a drag never toggles the section.
export function InspectorCard({
  id,
  order,
  onMove,
  children,
}: {
  id: InspectorOrderId;
  order: readonly InspectorOrderId[];
  onMove: (id: InspectorOrderId, target: InspectorOrderId, after?: boolean) => void;
  children: ReactNode;
}) {
  const t = useT();
  const label =
    id === "environment"
      ? t("rail.environment")
      : id === "context"
        ? t("rail.context")
        : id === "connectors"
          ? t("rail.connectors")
          : id === "changes"
            ? t("header.changes")
            : id === "sources"
              ? t("summary.sources")
              : id === "outputs"
                ? t("rail.outputs")
                : id === "subagents"
                  ? t("summary.subagents")
                  : t("summary.backgroundTasks");
  const [dragging, setDragging] = useState(false);
  const [target, setTarget] = useState<DragTarget>();
  const index = order.indexOf(id);
  const moveBy = (delta: number) => {
    const targetId = order[index + delta];
    if (targetId) onMove(id, targetId, delta > 0);
  };
  const onKeyDown = (event: KeyboardEvent<HTMLDivElement>) => {
    if (event.key !== "ArrowUp" && event.key !== "ArrowDown") return;
    event.preventDefault();
    event.stopPropagation();
    moveBy(event.key === "ArrowUp" ? -1 : 1);
  };
  const onDragStart = (event: DragEvent<HTMLDivElement>) => {
    event.dataTransfer?.setData("application/x-cmux-inspector-section", id);
    if (event.dataTransfer) event.dataTransfer.effectAllowed = "move";
    setDragging(true);
  };
  const onDragOver = (event: DragEvent<HTMLElement>) => {
    if (!dragging && !event.dataTransfer?.types.includes("application/x-cmux-inspector-section")) return;
    event.preventDefault();
    const box = event.currentTarget.getBoundingClientRect();
    setTarget({ id, after: event.clientY > box.top + box.height / 2 });
  };
  const onDrop = (event: DragEvent<HTMLElement>) => {
    event.preventDefault();
    const source = event.dataTransfer?.getData("application/x-cmux-inspector-section") as InspectorOrderId;
    if (source && source !== id) onMove(source, id, target?.after);
    setTarget(undefined);
    setDragging(false);
  };
  const onDragLeave = (event: DragEvent<HTMLElement>) => {
    const related = event.relatedTarget;
    if (related instanceof Node && event.currentTarget.contains(related)) return;
    setTarget(undefined);
  };
  const clearDragState = () => {
    setDragging(false);
    setTarget(undefined);
  };
  return (
    <article
      className="acpmux-chat-inspector-card"
      data-section-card={id}
      data-dragging={dragging || undefined}
      data-drop={target && target.id === id ? (target.after ? "after" : "before") : undefined}
      onDragOver={onDragOver}
      onDragLeave={onDragLeave}
      onDrop={onDrop}
      onDragEnd={clearDragState}
    >
      {children}
      {/* eslint-disable jsx-a11y/no-noninteractive-element-interactions, jsx-a11y/no-noninteractive-tabindex, jsx-a11y/prefer-tag-over-role -- Focusable drag affordance; Arrow keys reorder, with no activation action. */}
      <div
        role="group"
        aria-roledescription="drag handle"
        className="acpmux-chat-inspector-card__handle"
        aria-label={label}
        aria-keyshortcuts="ArrowUp ArrowDown"
        tabIndex={0}
        draggable
        onKeyDown={onKeyDown}
        onDragStart={onDragStart}
      >
        <span aria-hidden="true">⠿</span>
      </div>
      {/* eslint-enable jsx-a11y/no-noninteractive-element-interactions, jsx-a11y/no-noninteractive-tabindex, jsx-a11y/prefer-tag-over-role */}
    </article>
  );
}
