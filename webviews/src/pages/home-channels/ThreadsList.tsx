// A conversation's Threads view: its threads as work items, grouped Open then Resolved, newest
// activity first. A row is a status mark, the title, and one quiet line: owner, replies, last
// activity, and the faces of who replied. Filters narrow to my threads or the Chiefs' threads;
// Resolved folds. Row actions stay out of the resting list; the keyboard (j/k, Return, e) and
// the open thread's header act on a thread.
import type { Strings } from "../shared/i18n";
import { Avatar } from "./Avatar";
import { HomeIcon } from "./icons";
import type { ThreadFilter, WorkThread } from "./threads";
import type { HomeParticipant } from "./types";
import { relativeTime, useClock } from "./time";

export interface ThreadsListProps {
  threads: readonly WorkThread[];
  people: ReadonlyMap<string, HomeParticipant>;
  me?: string;
  filter: ThreadFilter;
  onFilter(filter: ThreadFilter): void;
  /** The keyboard's row. */
  focused?: string;
  /** The thread open on the right. */
  open?: string;
  /** Top-level messages that are not threads (they read in the Timeline). */
  loose: number;
  hasOlder: boolean;
  loadingOlder: boolean;
  onLoadOlder(): void;
  onOpen(id: string): void;
  onShowTimeline(): void;
  showResolved: boolean;
  onShowResolved(show: boolean): void;
  strings: Strings;
}

export function matchesFilter(
  thread: WorkThread,
  filter: ThreadFilter,
  me: string | undefined,
  people: ReadonlyMap<string, HomeParticipant>,
): boolean {
  if (filter === "mine") return thread.owner === me || thread.root.author === me || thread.authors.includes(me ?? "");
  if (filter === "chiefs") return people.get(thread.owner)?.chief === true;
  return true;
}

export function ThreadsList({
  threads,
  people,
  me,
  filter,
  onFilter,
  focused,
  open,
  loose,
  hasOlder,
  loadingOlder,
  onLoadOlder,
  onOpen,
  onShowTimeline,
  showResolved,
  onShowResolved,
  strings,
}: ThreadsListProps) {
  const { t, format } = strings;
  const now = useClock();
  const shown = threads.filter((thread) => matchesFilter(thread, filter, me, people));
  const openList = shown.filter((thread) => thread.status === "open");
  const resolved = shown.filter((thread) => thread.status === "resolved");
  const filters: ThreadFilter[] = ["all", "mine", "chiefs"];
  const row = (thread: WorkThread) => (
    <li key={thread.id}>
      <ThreadRow
        thread={thread}
        people={people}
        now={now}
        focused={thread.id === focused}
        active={thread.id === open}
        strings={strings}
        onOpen={onOpen}
      />
    </li>
  );
  return (
    <div className="hc-threads">
      <div className="hc-threads-bar" role="toolbar" aria-label={t("threads.filter")}>
        {filters.map((value) => (
          <button
            key={value}
            type="button"
            className={`hc-filter${filter === value ? " on" : ""}`}
            aria-pressed={filter === value}
            onClick={() => onFilter(value)}
          >
            {t(`threads.filter.${value}`)}
          </button>
        ))}
        <span className="hc-threads-count">
          {format("threads.summary", String(openList.length), String(resolved.length))}
        </span>
      </div>
      <div className="hc-threads-scroll">
        {shown.length === 0 ? (
          <div className="hc-threads-empty">
            <p className="hc-empty-title">{t(threads.length === 0 ? "threads.empty.title" : "threads.emptyFilter.title")}</p>
            <p className="hc-empty-body">{t(threads.length === 0 ? "threads.empty.body" : "threads.emptyFilter.body")}</p>
          </div>
        ) : (
          <>
            <h3 className="hc-group">
              <span>{t("threads.group.open")}</span>
              <span className="hc-group-count">{openList.length}</span>
            </h3>
            {openList.length === 0 ? (
              <p className="hc-group-none">{t("threads.allResolved")}</p>
            ) : (
              <ul className="hc-thread-rows">{openList.map(row)}</ul>
            )}
            {resolved.length > 0 && (
              <>
                <h3 className="hc-group">
                  <button
                    type="button"
                    className="hc-group-fold"
                    aria-expanded={showResolved}
                    onClick={() => onShowResolved(!showResolved)}
                  >
                    <span className={`hc-group-caret${showResolved ? " open" : ""}`} aria-hidden="true">
                      <HomeIcon name="chevronRight" size={14} />
                    </span>
                    <span>{t("threads.group.resolved")}</span>
                    <span className="hc-group-count">{resolved.length}</span>
                  </button>
                </h3>
                {showResolved && <ul className="hc-thread-rows resolved">{resolved.map(row)}</ul>}
              </>
            )}
          </>
        )}
        <div className="hc-threads-foot">
          {hasOlder && (
            <button type="button" className="hc-link-button" disabled={loadingOlder} onClick={onLoadOlder}>
              {t(loadingOlder ? "timeline.loadingOlder" : "threads.older")}
            </button>
          )}
          {loose > 0 && (
            <button type="button" className="hc-link-button" onClick={onShowTimeline}>
              {loose === 1 ? t("threads.looseOne") : format("threads.looseMany", String(loose))}
            </button>
          )}
        </div>
      </div>
    </div>
  );
}

function ThreadRow({
  thread,
  people,
  now,
  focused,
  active,
  strings,
  onOpen,
}: {
  thread: WorkThread;
  people: ReadonlyMap<string, HomeParticipant>;
  now: number;
  focused: boolean;
  active: boolean;
  strings: Strings;
  onOpen(id: string): void;
}) {
  const { t, format } = strings;
  const owner = people.get(thread.owner);
  const replies =
    thread.replyCount === 0
      ? t("threads.noReplies")
      : thread.replyCount === 1
        ? t("thread.replies.one")
        : format("thread.replies.many", String(thread.replyCount));
  return (
    <button
      type="button"
      className={`hc-thread-row${focused ? " focused" : ""}${active ? " active" : ""}${thread.unread > 0 ? " unread" : ""}`}
      data-thread={thread.id}
      aria-current={active ? "true" : undefined}
      onClick={() => onOpen(thread.id)}
    >
      <span
        className={`hc-status ${thread.status}`}
        aria-label={t(thread.status === "open" ? "status.open" : "status.resolved")}
      >
        <HomeIcon name={thread.status === "open" ? "statusOpen" : "statusResolved"} size={16} />
      </span>
      <span className="hc-thread-main">
        <span className="hc-thread-title">{thread.title}</span>
        <span className="hc-thread-meta">
          <Avatar participant={owner} size={16} />
          <span className="hc-thread-owner">{owner?.name ?? thread.owner}</span>
          <span className="hc-dot" aria-hidden="true">
            ·
          </span>
          <span>{replies}</span>
          {thread.unread > 0 && <span className="hc-thread-new">{format("thread.new", String(thread.unread))}</span>}
        </span>
      </span>
      <span className="hc-thread-side">
        <span className="hc-thread-faces" aria-hidden="true">
          {thread.authors.slice(0, 3).map((id) => (
            <Avatar key={id} participant={people.get(id)} size={18} />
          ))}
        </span>
        <time className="hc-thread-time">{relativeTime(thread.lastAt, now, strings)}</time>
      </span>
    </button>
  );
}
