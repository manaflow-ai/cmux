// The thread side panel: a header ("Thread" over the channel's name), the root message, an
// "N replies" line, the replies and a reply composer. Escape (or the close button) closes it. The
// replies come from the owner's thread read in pages ("Show More Replies"); the count is the
// owner's (every reply), plus replies that arrived after it.
import { useMemo, useState } from "react";
import type { Strings } from "../shared/i18n";
import { Composer } from "./Composer";
import { HomeIcon } from "./icons";
import { replyCount, threadMessages, threadTree, type TimelineRow } from "./model";
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
  /** Sends in the thread; `parent` is the reply answered (absent: the root). */
  onSend(text: string, parent?: string): Promise<boolean>;
  onCopyLink?(message: HomeMessage): void;
  /** The message a link opened. */
  highlight?: string;
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
  onCopyLink,
  highlight,
}: ThreadPanelProps) {
  const { t, format } = strings;
  const [replyTo, setReplyTo] = useState<HomeMessage | undefined>();
  const rows = useMemo<TimelineRow[]>(() => {
    const thread = threadMessages(messages, root);
    const list: TimelineRow[] = [];
    if (thread.root) list.push({ kind: "message", key: thread.root.id, message: thread.root, head: true });
    const count = replyCount(thread.replies, stats);
    if (count > 0) list.push({ kind: "replies", key: `replies-${root}`, count });
    // Tree order: each reply after its parent, indented by depth (threads nest without a limit).
    let previous: HomeMessage | undefined;
    for (const node of threadTree(thread.replies, root)) {
      list.push({
        kind: "message",
        key: node.message.id,
        message: node.message,
        head: previous?.author !== node.message.author || node.parent !== undefined,
        depth: node.depth,
        parent: node.parent,
      });
      previous = node.message;
    }
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
        onReply={(message) => setReplyTo(message.id === root ? undefined : message)}
        onCopyLink={onCopyLink}
        highlight={highlight}
        className="in-thread"
      />
      {hasMore && (
        <button type="button" className="hc-thread-more" disabled={loadingMore} onClick={onLoadMore}>
          {t("thread.more")}
        </button>
      )}
      {replyTo && (
        <div className="hc-thread-replying">
          <span>{format("thread.replyingTo", people.get(replyTo.author)?.name ?? replyTo.author)}</span>
          <button
            type="button"
            className="hc-icon-button"
            aria-label={t("thread.cancelReply")}
            title={t("thread.cancelReply")}
            onClick={() => setReplyTo(undefined)}
          >
            <HomeIcon name="close" size={14} />
          </button>
        </div>
      )}
      <Composer
        strings={strings}
        placeholder={t("composer.thread")}
        label={t("composer.thread")}
        disabled={!canSend}
        people={mentionable}
        onSend={async (text) => {
          const sent = await onSend(text, replyTo?.id);
          if (sent) setReplyTo(undefined);
          return sent;
        }}
      />
    </aside>
  );
}
