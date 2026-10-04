// The shared layout of the viewer empty states (diff without a repository, markdown without a
// file): a centered column with a title, a line of help, the primary action, the recent items and
// a drop target over the whole page. DiffEmptyState and MarkdownEmptyState own the host calls.
import { useRef, useState, type DragEvent, type KeyboardEvent, type ReactNode } from "react";
import type { Strings } from "../pages/shared/i18n";
import { dragMayOpen, droppedItem, type DroppedItem } from "./drop";
import { EmptyIcon, type EmptyIconName } from "./icons";
import { baseName, tildePath, type RecentItem } from "./ops";
import { E } from "./strings";
import { relativeTime } from "./time";

export interface EmptyStateProps {
  kind: "diff" | "markdown" | "editor";
  title: string;
  subtitle: string;
  /** The text over the page while something is dragged onto it. */
  dropText: string;
  onDrop(item: DroppedItem): void;
  /** An error line under the actions. */
  error?: string | null;
  children: ReactNode;
}

export function EmptyState({ kind, title, subtitle, dropText, onDrop, error, children }: EmptyStateProps) {
  const [dragging, setDragging] = useState(false);
  const depth = useRef(0);
  const enter = (event: DragEvent<HTMLDivElement>) => {
    if (!dragMayOpen(event.dataTransfer)) return;
    event.preventDefault();
    depth.current += 1;
    setDragging(true);
  };
  const leave = () => {
    depth.current = Math.max(0, depth.current - 1);
    if (depth.current === 0) setDragging(false);
  };
  return (
    <div
      className="ve-page"
      data-viewer-empty={kind}
      data-dragging={dragging || undefined}
      onDragEnter={enter}
      onDragOver={(event) => {
        if (!dragMayOpen(event.dataTransfer)) return;
        event.preventDefault();
        event.dataTransfer.dropEffect = "copy";
      }}
      onDragLeave={leave}
      onDrop={(event) => {
        event.preventDefault();
        depth.current = 0;
        setDragging(false);
        const item = droppedItem(event.dataTransfer);
        if (item) onDrop(item);
      }}
    >
      <div className="ve-column">
        <h1 className="ve-title">{title}</h1>
        <p className="ve-subtitle">{subtitle}</p>
        {children}
        {error ? (
          <p className="ve-error" role="alert">
            {error}
          </p>
        ) : null}
      </div>
      {dragging ? (
        <div className="ve-drop" aria-hidden="true">
          <span className="ve-drop-text">{dropText}</span>
        </div>
      ) : null}
    </div>
  );
}

export interface RecentListProps {
  items: readonly RecentItem[] | null;
  home: string | null;
  icon: EmptyIconName;
  strings: Strings;
  label: string;
  emptyText: string;
  /** Milliseconds now, for the relative times (tests pin it). */
  now?: number;
  /** Takes focus when it mounts with items, so arrows and Return work at once. */
  autoFocus?: boolean;
  onOpen(item: RecentItem): void;
}

/** The recent items: a listbox; Up, Down, Home and End move, Return or a click opens. */
export function RecentList({
  items,
  home,
  icon,
  strings,
  label,
  emptyText,
  now = Date.now(),
  autoFocus = true,
  onOpen,
}: RecentListProps) {
  const [highlight, setHighlight] = useState(0);
  const focused = useRef(false);
  if (items == null) return <div className="ve-recents" aria-busy="true" />;
  const listId = `ve-recents-${icon}`;
  const onKeyDown = (event: KeyboardEvent<HTMLDivElement>) => {
    if (event.metaKey || event.altKey || event.ctrlKey) return;
    const last = items.length - 1;
    const moves: Record<string, number> = {
      ArrowDown: Math.min(last, highlight + 1),
      ArrowUp: Math.max(0, highlight - 1),
      Home: 0,
      End: last,
    };
    if (event.key in moves) {
      event.preventDefault();
      setHighlight(moves[event.key]);
    } else if (event.key === "Enter" || event.key === " ") {
      event.preventDefault();
      const item = items[highlight];
      if (item) onOpen(item);
    }
  };
  return (
    <section className="ve-recents" aria-label={label}>
      <h2 className="ve-section-title">{strings.t(E.recentHeading)}</h2>
      {items.length === 0 ? (
        <p className="ve-recents-empty">{emptyText}</p>
      ) : (
        <div
          ref={(element) => {
            if (!element || !autoFocus || focused.current) return;
            focused.current = true;
            element.focus({ preventScroll: true });
          }}
          className="ve-recent-list"
          // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
          role="listbox"
          tabIndex={0}
          aria-label={label}
          aria-activedescendant={`${listId}-${Math.min(highlight, items.length - 1)}`}
          onKeyDown={onKeyDown}
        >
          {items.map((item, index) => (
            <div
              key={item.path}
              id={`${listId}-${index}`}
              className="ve-recent"
              // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
              role="option"
              tabIndex={-1}
              aria-selected={index === highlight}
              title={item.path}
              onMouseMove={() => index !== highlight && setHighlight(index)}
              onMouseDown={(event) => {
                event.preventDefault();
                onOpen(item);
              }}
            >
              <EmptyIcon name={icon} />
              <span className="ve-recent-text">
                <span className="ve-recent-name">{item.name || baseName(item.path)}</span>
                <span className="ve-recent-path">
                  <TailPath path={tildePath(parentOf(item.path), home)} />
                  {item.branch ? <span className="ve-recent-branch">{item.branch}</span> : null}
                </span>
              </span>
              <span className="ve-recent-time">{relativeTime(item.openedAt, now, strings.language)}</span>
            </div>
          ))}
        </div>
      )}
    </section>
  );
}

/** A path that, when too long, drops its start ("…/worktrees/feat-x") so the folder stays visible. */
export function TailPath({ path }: { path: string }) {
  return (
    <span className="ve-tail-path">
      {/* The marks keep `~/` and `/` in place inside the right-to-left box that moves the ellipsis. */}
      {`\u200e${path}\u200e`}
    </span>
  );
}

function parentOf(path: string): string {
  const index = path.replace(/\/+$/, "").lastIndexOf("/");
  return index <= 0 ? "/" : path.slice(0, index);
}
