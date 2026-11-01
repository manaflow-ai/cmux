// One Session Info section: its title with a disclosure triangle and a one-line value on the right
// (a count, a percent), folding its body. Without `onOpenChange` the head is plain text (Context
// before the agent reports usage). With `icon`, the head starts with it, so a section that is one
// line lines up with the rows above it (the rail's top block, SessionInfo.tsx `RAIL_LAYOUT`).
// `bare` draws the body alone, with no head: rows that need no title over them. Inside the panel's
// list (SessionInfoGroup.tsx) it also has the six-dot handle that moves it anywhere in the panel, at
// the right end of its head (sessionInfo.css).
import type { ReactNode } from "react";
import { Disclosure } from "../../../ui/Disclosure";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { rowIconSize } from "../icons/iconSize";
import { useReorder } from "./SessionInfoGroup";
import type { SessionInfoSectionId } from "./sessionInfoState";

const ROW_ICON = rowIconSize(12);

/// The shared whole-row fold used by every expandable list in Session Info. Keeping the button
/// here makes its keyboard semantics and visual contract available to new sections (Sources, etc.).
export function SessionInfoFold({
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
      className={["acpmux-session-info-fold", className].filter(Boolean).join(" ")}
      aria-expanded={open}
      onClick={onToggle}
    >
      {children}
    </button>
  );
}

/// Six dots, drawn here: the icon pack has no grip glyph.
const GRIP_DOTS = [3, 7, 11].flatMap((y) => [1.25, 4.75].map((x) => ({ x, y })));

function ReorderHandle({ id, title }: { id: SessionInfoSectionId; title: string }) {
  const reorder = useReorder();
  const t = useT();
  if (!reorder) return null;
  return (
    <button
      type="button"
      className="acpmux-session-info-section__handle"
      aria-label={t("sessionInfo.reorderSection", { section: title })}
      aria-keyshortcuts="ArrowUp ArrowDown"
      onPointerDown={(event) => reorder.start(id, event)}
      onKeyDown={(event) => {
        if (event.key !== "ArrowUp" && event.key !== "ArrowDown") return;
        event.preventDefault();
        reorder.step(id, event.key === "ArrowUp" ? -1 : 1);
      }}
    >
      <svg width="6" height="14" viewBox="0 0 6 14" aria-hidden="true">
        {GRIP_DOTS.map(({ x, y }) => (
          <circle key={`${x}-${y}`} cx={x} cy={y} r="0.9" fill="currentColor" />
        ))}
      </svg>
    </button>
  );
}

export function SessionInfoSection({
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
      {icon && (
        <Icon name={icon} size={ROW_ICON} row fit className="acpmux-session-info-section__icon acpmux-row-glyph" />
      )}
      <span className="acpmux-session-info-section__title">{title}</span>
      {foldable && (
        <Icon
          name={open ? "disclosure.expanded" : "disclosure.collapsed"}
          size={12}
          className="acpmux-session-info-section__fold"
        />
      )}
      {meta && <span className="acpmux-session-info-section__meta">{meta}</span>}
    </>
  );
  const dragging = useReorder()?.dragging === id;
  return (
    <section
      className="acpmux-session-info-section"
      data-section={id}
      data-bare={bare || undefined}
      data-dragging={dragging || undefined}
      aria-label={title}
    >
      <ReorderHandle id={id as SessionInfoSectionId} title={title} />
      {bare ? (
        children
      ) : onOpenChange ? (
        <Disclosure
          label={head(true)}
          open={open}
          onOpenChange={onOpenChange}
          className="acpmux-session-info-section__disclosure"
        >
          {children}
        </Disclosure>
      ) : (
        <div className="acpmux-session-info-section__head">{head(false)}</div>
      )}
    </section>
  );
}
