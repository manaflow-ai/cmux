// A thread in the timeline: one titled row in place of its root message, like an issue in a list:
// the status mark, the title, the owner, then on the right the reply authors, the count and the
// last reply's time. Pressing it opens the thread sheet. The root itself shows in the sheet.
import { memo } from "react";
import type { Strings } from "../shared/i18n";
import { Avatar } from "./Avatar";
import type { ThreadSummary } from "./model";
import type { ThreadObject } from "./threads";
import type { HomeParticipant } from "./types";

export interface ThreadRowProps {
  thread: ThreadObject;
  summary: ThreadSummary;
  people: ReadonlyMap<string, HomeParticipant>;
  strings: Strings;
  stamp(at: number): string;
  open: boolean;
  focused: boolean;
  highlighted: boolean;
  onOpen(): void;
}

export const ThreadRow = memo(function ThreadRow({
  thread,
  summary,
  people,
  strings,
  stamp,
  open,
  focused,
  highlighted,
  onOpen,
}: ThreadRowProps) {
  const { t, format } = strings;
  const owner = people.get(thread.owner)?.name ?? thread.owner;
  const count = summary.count === 1 ? t("thread.replies.one") : format("thread.replies.many", String(summary.count));
  const status = t(thread.status === "open" ? "thread.status.open" : "thread.status.resolved");
  return (
    <div className="lg-thread-line">
      <button
        type="button"
        data-thread-row={thread.root}
        data-status={thread.status}
        className={`lg-thread-row${open ? " open" : ""}${focused ? " focused" : ""}${highlighted ? " highlighted" : ""}`}
        aria-current={focused ? "true" : undefined}
        aria-label={`${thread.title}, ${status}, ${count}`}
        onClick={onOpen}
      >
        <span className={`lg-status ${thread.status}`} title={status} aria-hidden="true" />
        <span className="lg-thread-title">{thread.title}</span>
        <span className="lg-thread-owner">{owner}</span>
        {summary.unread > 0 && <span className="lg-thread-new">{format("thread.new", String(summary.unread))}</span>}
        <span className="lg-thread-faces" aria-hidden="true">
          {summary.authors.slice(0, 3).map((id) => (
            <Avatar key={id} participant={people.get(id)} size={16} />
          ))}
        </span>
        <span className="lg-thread-count">{count}</span>
        <time className="lg-thread-time">{stamp(summary.lastAt)}</time>
      </button>
    </div>
  );
});
