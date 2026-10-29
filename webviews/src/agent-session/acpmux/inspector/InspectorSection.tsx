// One Inspector section: its title with a disclosure triangle and a one-line value on the right
// (a count, a percent), folding its body. Without `onOpenChange` the head is plain text (Context
// before the agent reports usage). With `icon`, the head starts with it, so a section that is one
// line lines up with the rows above it (the rail's top block, ChatInspector.tsx `RAIL_LAYOUT`).
// `bare` draws the body alone, with no head: rows that need no title over them. Inside a block
// (InspectorGroup.tsx) it also has the six-dot handle that moves it.
import type { ReactNode } from "react";
import { Disclosure } from "../../../ui/Disclosure";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { rowIconSize } from "../icons/iconSize";
import { useReorder } from "./InspectorGroup";
import type { InspectorSectionId } from "./inspectorState";

const ROW_ICON = rowIconSize(12);

/// The shared whole-row fold used by every expandable list in Session Info. Keeping the button
/// here makes its keyboard semantics and visual contract available to new sections (Sources, etc.).
export function InspectorFold({
  open,
  onToggle,
  className,
  children,
}: {
  open: boolean;
  onToggle: () => void;
  className?: string;
  children: ReactNode;
}) {
  return (
    <button
      type="button"
      className={["acpmux-chat-inspector-fold", className].filter(Boolean).join(" ")}
      aria-expanded={open}
      onClick={onToggle}
    >
      {children}
    </button>
  );
}

/// Six dots, drawn here: the icon pack has no grip glyph.
const GRIP_DOTS = [3, 7, 11].flatMap((y) => [2, 6].map((x) => ({ x, y })));

function ReorderHandle({ id, title }: { id: InspectorSectionId; title: string }) {
  const reorder = useReorder();
  const t = useT();
  if (!reorder) return null;
  return (
    <button
      type="button"
      className="acpmux-chat-inspector-section__handle"
      aria-label={t("chatInspector.reorderSection", { section: title })}
      onPointerDown={(event) => reorder.start(id, event)}
      onPointerMove={reorder.move}
      onPointerUp={reorder.end}
      onPointerCancel={reorder.end}
      onLostPointerCapture={reorder.end}
      onKeyDown={(event) => {
        if (event.key !== "ArrowUp" && event.key !== "ArrowDown") return;
        event.preventDefault();
        reorder.step(id, event.key === "ArrowUp" ? -1 : 1);
      }}
    >
      <svg width="8" height="14" viewBox="0 0 8 14" aria-hidden="true">
        {GRIP_DOTS.map(({ x, y }) => (
          <circle key={`${x}-${y}`} cx={x} cy={y} r="1" fill="currentColor" />
        ))}
      </svg>
    </button>
  );
}

export function InspectorSection({
  id,
  title,
  open,
  onOpenChange,
  meta,
  icon,
  bare = false,
  children,
}: {
  id: string;
  title: string;
  open: boolean;
  onOpenChange?: (open: boolean) => void;
  meta?: ReactNode;
  icon?: string;
  bare?: boolean;
  children?: ReactNode;
}) {
  const head = (foldable: boolean) => (
    <>
      {icon && <Icon name={icon} size={ROW_ICON} row className="acpmux-chat-inspector-section__icon" />}
      <span className="acpmux-chat-inspector-section__title">{title}</span>
      {foldable && (
        <Icon
          name={open ? "disclosure.expanded" : "disclosure.collapsed"}
          size={10}
          className="acpmux-chat-inspector-section__fold"
        />
      )}
      {meta && <span className="acpmux-chat-inspector-section__meta">{meta}</span>}
    </>
  );
  const dragging = useReorder()?.dragging === id;
  return (
    <section
      className="acpmux-chat-inspector-section"
      data-section={id}
      data-bare={bare || undefined}
      data-dragging={dragging || undefined}
      aria-label={title}
    >
      <ReorderHandle id={id as InspectorSectionId} title={title} />
      {bare ? (
        children
      ) : onOpenChange ? (
        <Disclosure
          label={head(true)}
          open={open}
          onOpenChange={onOpenChange}
          className="acpmux-chat-inspector-section__disclosure"
        >
          {children}
        </Disclosure>
      ) : (
        <div className="acpmux-chat-inspector-section__head">{head(false)}</div>
      )}
    </section>
  );
}
