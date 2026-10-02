import type { CSSProperties, ReactNode } from "react";
import { useScrollArea } from "./scroll";
import {
  IconArchive,
  IconBell,
  IconChevronDown,
  IconCompose,
  IconFolder,
  IconFolderOpen,
  IconMore,
  IconPin,
  IconPlus,
  IconSearch,
} from "./icons";
import { anchorProps, SIDEBAR_TITLE_ANCHOR } from "./anchors";

export type SidebarThread = {
  /** Stable id for event handlers (defaults to the title). */
  id?: string;
  title: string;
  /** Selected row: filled background. */
  selected?: boolean;
  /** Hovered row: filled background plus pin/archive buttons. */
  hover?: boolean;
  /** Replace the trailing hover buttons. */
  trailing?: ReactNode;
  /** Extra class on the row (e.g. a muted "No chats" placeholder). */
  className?: string;
};

export type SidebarProject = {
  id?: string;
  name: string;
  threads: SidebarThread[];
  /** Project row itself selected (e.g. new chat in that project). */
  selected?: boolean;
  hover?: boolean;
  /** Collapsed projects show a closed folder and no threads. */
  collapsed?: boolean;
  /** Render "Show more" under the threads. */
  showMore?: boolean;
  /** Replace the folder icon. */
  icon?: ReactNode;
  /** Right-side hover buttons on the project row (e.g. ⋯ and compose). */
  trailing?: ReactNode;
};

export type SidebarProps = {
  projects: SidebarProject[];
  recents: SidebarThread[];
  /** Header title, default "Codex". */
  title?: string;
  /** Pointer over the sidebar: brighter scrollbar thumb. */
  hovered?: boolean;
  /** Pointer over the Recents header: shows chevron, ⋯ and compose buttons. */
  recentsHover?: boolean;
  /** Pointer over the Projects header. */
  projectsHover?: boolean;
  /** Projects header decorations: a chevron after the label, or chevron + ⋯ + add. */
  projectsHeader?: "chevron" | "actions";
  /** Recents header decorations without `recentsHover`: "chevron" shows only the chevron. */
  recentsHeader?: "chevron" | "actions";
  /** Captured scroll offset of the real scroll container, px. */
  scrollTop?: number;
  /**
   * Overlay thumb: derived from the live scroll position by default; a fixed
   * `{top,height}` (sidebar-local px) pins a captured one; null hides it.
   */
  scrollThumb?: { top: number; height: number } | null;
  /** Interaction. Ids are the thread/project `id` (or title/name). */
  onThreadClick?: (id: string) => void;
  onProjectClick?: (id: string) => void;
  onShowMore?: (projectId: string) => void;
  onHover?: (
    target: { kind: "thread" | "project"; id: string } | { kind: "section"; id: "projects" | "recents" } | null,
  ) => void;
  onTitleClick?: () => void;
  onNewChat?: () => void;
  /** The header's magnifier (search chats). */
  onSearch?: () => void;
  onScroll?: (top: number) => void;
  /** Extra absolutely-positioned content (menus anchored to the sidebar). */
  children?: ReactNode;
  style?: CSSProperties;
};

function Row({
  thread,
  indent,
  className = "",
  onClick,
  onHover,
}: {
  thread: SidebarThread;
  indent: boolean;
  className?: string;
  onClick?: () => void;
  onHover?: (on: boolean) => void;
}) {
  return (
    <button
      type="button"

      className={`cx-row${indent ? " cx-row--indent" : ""}${thread.selected ? " is-selected" : ""}${thread.hover ? " is-hover" : ""} ${className} ${thread.className ?? ""}`}
      onClick={onClick}
      onPointerEnter={onHover && (() => onHover(true))}
      onPointerLeave={onHover && (() => onHover(false))}
    >
      <span className="cx-row__text">{thread.title}</span>
      {thread.trailing ??
        (thread.hover && (
          <span className="cx-row__actions">
            <IconPin className="cx-row__pin" />
            <IconArchive className="cx-row__archive" />
          </span>
        ))}
    </button>
  );
}

/** Sticky "New chat" row height: the scroll track starts below it (93 - 44 sidebar px). */
const TRACK_INSET_TOP = 49;
const TRACK_INSET_BOTTOM = 4;

/** Codex sidebar column: header, New chat, Projects (folders + threads), Recents. */
export function Sidebar({
  projects,
  recents,
  title = "Codex",
  hovered = false,
  recentsHover = false,
  projectsHover = false,
  projectsHeader,
  recentsHeader,
  scrollTop = 0,
  scrollThumb,
  onThreadClick,
  onProjectClick,
  onShowMore,
  onHover,
  onTitleClick,
  onNewChat,
  onSearch,
  onScroll,
  children,
  style,
}: SidebarProps) {
  const scroll = useScrollArea(scrollTop, {
    insetStart: TRACK_INSET_TOP,
    insetEnd: TRACK_INSET_BOTTOM,
    onScroll,
  });
  const derived = scroll.thumb && { top: scroll.thumb.top + 44, height: scroll.thumb.height };
  const thumb = scrollThumb === undefined ? derived : scrollThumb;
  const hoverThread = (id: string) => onHover && ((on: boolean) => onHover(on ? { kind: "thread", id } : null));
  const threadRow = (t: SidebarThread, i: number, indent: boolean) => {
    const id = t.id ?? t.title;
    return (
      <Row
        key={id + i}
        thread={t}
        indent={indent}
        onClick={onThreadClick && (() => onThreadClick(id))}
        onHover={hoverThread(id)}
      />
    );
  };
  return (
    <aside className={`cx-sidebar${hovered ? " is-hovered" : ""}`} style={style}>
      <div className="cx-sidebar__header">
        <button
          type="button"
          className="cx-sidebar__title"
          onClick={onTitleClick}
          {...anchorProps(SIDEBAR_TITLE_ANCHOR)}
        >
          {title}
        </button>
        <IconChevronDown className="cx-sidebar__title-chevron" size={16} />
        <IconBell className="cx-sidebar__bell" size={16} />
        <button type="button" className="cx-sidebar__search" aria-label="Search chats" onClick={onSearch}>
          <IconSearch size={16} />
        </button>
      </div>
      <div className="cx-sidebar__body" ref={scroll.ref} {...scroll.handlers}>
        <div
          className="cx-sidebar__content"
          style={scroll.residual ? { transform: `translateY(${-scroll.residual}px)` } : undefined}
        >
          <div className="cx-sidebar__sticky">
            <button type="button" className="cx-row cx-row--newchat" onClick={onNewChat}>
              <IconCompose className="cx-row__icon" size={16} />
              <span className="cx-row__text">New chat</span>
            </button>
            {/* Shown while rows scroll under the pinned row (scroll-state query in shell.css). */}
            <span className="cx-sidebar__stuck-rule" aria-hidden />
          </div>

          <div
            className={`cx-section${projectsHover ? " is-hover" : ""}`}
            onPointerEnter={onHover && (() => onHover({ kind: "section", id: "projects" }))}
            onPointerLeave={onHover && (() => onHover(null))}
          >
            <span className="cx-section__label">Projects</span>
            {projectsHeader && <IconChevronDown className="cx-section__chevron" size={18} strokeWidth={1.1} />}
            {projectsHeader === "actions" && (
              <>
                <IconMore className="cx-section__more" size={16} />
                <IconPlus className="cx-section__compose" size={16} />
              </>
            )}
          </div>
          {projects.map((p) => {
            const id = p.id ?? p.name;
            return (
              <div key={id} className={`cx-project${p.collapsed ? " cx-project--collapsed" : ""}`}>
                <button
                  type="button"

                  className={`cx-row cx-row--project${p.selected ? " is-selected" : ""}${p.hover ? " is-hover" : ""}`}
                  onClick={onProjectClick && (() => onProjectClick(id))}
                  onPointerEnter={onHover && (() => onHover({ kind: "project", id }))}
                  onPointerLeave={onHover && (() => onHover(null))}
                >
                  {p.icon ??
                    (p.collapsed ? (
                      <IconFolder className="cx-row__icon" size={16} />
                    ) : (
                      <IconFolderOpen className="cx-row__icon" size={16} />
                    ))}
                  <span className="cx-row__text">{p.name}</span>
                  {p.trailing}
                </button>
                {!p.collapsed && p.threads.map((t, i) => threadRow(t, i, true))}
                {!p.collapsed && p.showMore && (
                  <Row
                    thread={{ title: "Show more" }}
                    indent
                    className="cx-row--more"
                    onClick={onShowMore && (() => onShowMore(id))}
                  />
                )}
              </div>
            );
          })}

          <div
            className={`cx-section cx-section--recents${recentsHover ? " is-hover" : ""}`}
            onPointerEnter={onHover && (() => onHover({ kind: "section", id: "recents" }))}
            onPointerLeave={onHover && (() => onHover(null))}
          >
            <span className="cx-section__label">Recents</span>
            {!recentsHover && recentsHeader && (
              <IconChevronDown className="cx-section__chevron" size={18} strokeWidth={1.1} />
            )}
            {(recentsHover || recentsHeader === "actions") && (
              <>
                <IconChevronDown className="cx-section__chevron" size={18} strokeWidth={1.1} />
                <IconMore className="cx-section__more" size={16} />
                <IconCompose className="cx-section__compose" size={16} />
              </>
            )}
          </div>
          {recents.map((t, i) => threadRow(t, i, false))}
        </div>
      </div>
      {thumb && <span className="cx-sidebar__thumb" style={{ top: thumb.top, height: thumb.height }} />}
      {children}
    </aside>
  );
}
