// The thread sheet: slides in from the end edge over the timeline (not a third column, so the
// page works at the Home dock width). A thread is an object: the header shows its status (press
// it or E to resolve or reopen), where it lives, its title and one muted line (owner, replies,
// people). Then the root, the replies in tree order with depth rails (capped at 4 indents), and a
// reply composer; Reply on any reply nests under it. Escape closes the sheet.
import { useMemo, useState } from "react";
import type { Strings } from "../shared/i18n";
import { Composer } from "./Composer";
import { HomeIcon } from "./icons";
import { replyCount, threadMessages, threadTree, type TimelineRow } from "./model";
import type { ThreadObject } from "./threads";
import { Timeline } from "./Timeline";
import type { HomeMessage, HomeParticipant, HomeThreadStats } from "./types";

export interface ThreadSheetProps {
  root: string;
  /** The thread object (absent while the root loads). */
  thread?: ThreadObject;
  /** The conversation's name as the header shows it ("#release", "Builder"). */
  place: string;
  messages: readonly HomeMessage[];
  stats?: HomeThreadStats;
  hasMore?: boolean;
  loadingMore?: boolean;
  onLoadMore?(): void;
  people: ReadonlyMap<string, HomeParticipant>;
  mentionable: readonly HomeParticipant[];
  me?: string;
  strings: Strings;
  canSend: boolean;
  editing?: string;
  highlight?: string;
  onClose(): void;
  onToggleStatus(): void;
  onSend(text: string, parent?: string): Promise<boolean>;
  onCopyLink(message: HomeMessage): void;
  onReact(message: HomeMessage, value: string): void;
  onEditStart?(message: HomeMessage): void;
  onEditEnd?(): void;
  onEdit?(message: HomeMessage, text: string): Promise<boolean>;
  onRetract?(message: HomeMessage): void;
  pendingState(key: string): "sending" | "failed" | undefined;
  onRetry(key: string): void;
  onDiscard(key: string): void;
}

export function ThreadSheet({
  root,
  thread,
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
  highlight,
  onClose,
  onToggleStatus,
  onSend,
  onCopyLink,
  onReact,
  onEditStart,
  onEditEnd,
  onEdit,
  onRetract,
  pendingState,
  onRetry,
  onDiscard,
}: ThreadSheetProps) {
  const { t, format } = strings;
  const [replyTo, setReplyTo] = useState<HomeMessage | undefined>();
  const tree = useMemo(() => threadMessages(messages, root), [messages, root]);
  const count = replyCount(tree.replies, stats);
  const rows = useMemo<TimelineRow[]>(() => {
    const list: TimelineRow[] = [];
    if (tree.root) list.push({ kind: "message", key: tree.root.id, message: tree.root, head: true });
    if (count > 0) list.push({ kind: "replies", key: `replies-${root}`, count });
    let previous: HomeMessage | undefined;
    for (const node of threadTree(tree.replies, root)) {
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
  }, [tree, root, count]);
  const authors = new Set([...(tree.root ? [tree.root.author] : []), ...tree.replies.map((m) => m.author)]);
  const owner = thread ? (people.get(thread.owner)?.name ?? thread.owner) : "";
  const resolved = thread?.status === "resolved";
  return (
    <aside className="lg-sheet" data-status={thread?.status ?? "open"} aria-label={thread?.title || t("thread.title")}>
      <header className="lg-sheet-header">
        <div className="lg-sheet-bar">
          <button
            type="button"
            className={`lg-status-button${resolved ? " resolved" : ""}`}
            onClick={onToggleStatus}
            title={t(resolved ? "thread.reopen" : "thread.resolve")}
            aria-keyshortcuts="E"
          >
            <span className={`lg-status ${resolved ? "resolved" : "open"}`} aria-hidden="true" />
            {t(resolved ? "thread.status.resolved" : "thread.status.open")}
          </button>
          <span className="lg-sheet-place">{place}</span>
          <span className="lg-spacer" />
          {tree.root && (
            <button
              type="button"
              className="hc-icon-button"
              aria-label={t("action.copyLink")}
              title={t("action.copyLink")}
              onClick={() => tree.root && onCopyLink(tree.root)}
            >
              <HomeIcon name="link" size={16} />
            </button>
          )}
          <button
            type="button"
            className="hc-icon-button"
            aria-label={t("thread.close")}
            title={t("thread.close")}
            onClick={onClose}
          >
            <HomeIcon name="close" size={16} />
          </button>
        </div>
        <h2 className="lg-sheet-title">{thread?.title || t("thread.title")}</h2>
        <p className="lg-sheet-meta">
          {owner && <span>{format("thread.owner", owner)}</span>}
          <span>{count === 1 ? t("thread.replies.one") : format("thread.replies.many", String(count))}</span>
          <span>{format("thread.people", String(authors.size))}</span>
        </p>
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
        pendingState={pendingState}
        onRetry={onRetry}
        onDiscard={onDiscard}
        className="in-thread"
      />
      {hasMore && (
        <button type="button" className="hc-thread-more" disabled={loadingMore} onClick={onLoadMore}>
          {t("thread.more")}
        </button>
      )}
      <div className="lg-sheet-compose">
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
      </div>
    </aside>
  );
}
