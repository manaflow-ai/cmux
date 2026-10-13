// The thread side panel: a header ("Thread" over the channel's name), the root message, an
// "N replies" line, the replies and a reply composer. Escape (or the close button) closes it. The
// replies come from the owner's thread read in pages ("Show More Replies"); the count is the
// owner's (every reply), plus replies that arrived after it.
import { useMemo } from "react";
import type { Strings } from "../shared/i18n";
import { Composer } from "./Composer";
import { HomeIcon } from "./icons";
import { replyCount, threadMessages, type TimelineRow } from "./model";
import { Timeline } from "./Timeline";
import type { HomeMessage, HomeParticipant, HomeThreadStats } from "./types";

export interface ThreadPanelProps {
  root: string;
  /** The conversation's name as the header shows it ("#release", "Builder"). */
  place: string;
  messages: readonly HomeMessage[];
  /** The owner's stats of this thread (absent from a host without them). */
  stats?: HomeThreadStats;
  /** More replies follow the loaded ones. */
  hasMore?: boolean;
  loadingMore?: boolean;
  onLoadMore?(): void;
  people: ReadonlyMap<string, HomeParticipant>;
  mentionable: readonly HomeParticipant[];
  me?: string;
  strings: Strings;
  canSend: boolean;
  editing?: string;
  onClose(): void;
  onSend(text: string): Promise<boolean>;
  onReact(message: HomeMessage, value: string): void;
  onEditStart?(message: HomeMessage): void;
  onEditEnd?(): void;
  onEdit?(message: HomeMessage, text: string): Promise<boolean>;
  onRetract?(message: HomeMessage): void;
}

export function ThreadPanel({
  root,
  place,
  messages,
  stats,
  hasMore = false,
  loadingMore = false,
  onLoadMore,
  people,
  mentionable,
  me,
  strings,
  canSend,
  editing,
  onClose,
  onSend,
  onReact,
  onEditStart,
  onEditEnd,
  onEdit,
  onRetract,
}: ThreadPanelProps) {
  const { t } = strings;
  const rows = useMemo<TimelineRow[]>(() => {
    const thread = threadMessages(messages, root);
    const list: TimelineRow[] = [];
    if (thread.root) list.push({ kind: "message", key: thread.root.id, message: thread.root, head: true });
    const count = replyCount(thread.replies, stats);
    if (count > 0) list.push({ kind: "replies", key: `replies-${root}`, count });
    thread.replies.forEach((message, index) =>
      list.push({
        kind: "message",
        key: message.id,
        message,
        head: index === 0 || thread.replies[index - 1]!.author !== message.author,
      }),
    );
    return list;
  }, [messages, root, stats]);
  return (
    <aside className="hc-thread" aria-label={t("thread.title")}>
      <header className="hc-thread-header">
        <div className="hc-thread-heading">
          <span className="hc-thread-title">{t("thread.title")}</span>
          <span className="hc-thread-place">{place}</span>
        </div>
        <button
          type="button"
          className="hc-icon-button"
          aria-label={t("thread.close")}
          title={t("thread.close")}
          onClick={onClose}
        >
          <HomeIcon name="close" size={18} />
        </button>
      </header>
      <Timeline
        conversation={`thread:${root}`}
        rows={rows}
        people={people}
        me={me}
        strings={strings}
        loadingOlder={false}
        editing={editing}
        onLoadOlder={() => undefined}
        onReact={onReact}
        onEditStart={onEditStart}
        onEditEnd={onEditEnd}
        onEdit={onEdit}
        onRetract={onRetract}
        className="in-thread"
      />
      {hasMore && (
        <button type="button" className="hc-thread-more" disabled={loadingMore} onClick={onLoadMore}>
          {t("thread.more")}
        </button>
      )}
      <Composer
        strings={strings}
        placeholder={t("composer.thread")}
        label={t("composer.thread")}
        disabled={!canSend}
        people={mentionable}
        onSend={onSend}
      />
    </aside>
  );
}
