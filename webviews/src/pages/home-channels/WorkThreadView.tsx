// One thread, full height: a header that is the thread object (where it lives, its title, its
// status control and owner picker, the reply count and Copy Link), then the root and every reply
// in tree order, indented by depth (at most 4 levels; deeper replies keep the last indent and name
// their parent), then the reply composer. Reply on any message answers that message (threads nest
// without a limit); `r` does the same for the keyboard's message. Escape or Back closes it.
import { Fragment, useMemo } from "react";
import { Menu, MenuButton, MenuItem, MenuPopup, MenuSeparator } from "../../ui/Menu";
import type { Strings } from "../shared/i18n";
import { Avatar } from "./Avatar";
import { Composer } from "./Composer";
import { HomeIcon } from "./icons";
import { threadMessages, threadTree, type TimelineRow } from "./model";
import type { ThreadStatus, WorkThread } from "./threads";
import { Timeline } from "./Timeline";
import { relativeTime, useClock } from "./time";
import type { HomeMessage, HomeParticipant } from "./types";

export interface WorkThreadViewProps {
  thread: WorkThread;
  /** The conversation's name as the header shows it ("#release"). */
  place: string;
  messages: readonly HomeMessage[];
  pendingIds: ReadonlyMap<string, "sending" | "failed">;
  hasMore?: boolean;
  loadingMore?: boolean;
  onLoadMore?(): void;
  people: ReadonlyMap<string, HomeParticipant>;
  members: readonly HomeParticipant[];
  me?: string;
  strings: Strings;
  canSend: boolean;
  editing?: string;
  /** The keyboard's message in the thread. */
  focused?: string;
  replyTo?: HomeMessage;
  onReplyTo(message: HomeMessage | undefined): void;
  /** Bumped by the keyboard (r): the reply field takes the focus. */
  focusComposer: number;
  onClose(): void;
  onStatus(status: ThreadStatus): void;
  onOwner(owner: string): void;
  onSend(text: string, parent?: string): Promise<boolean>;
  onCopyLink(message: HomeMessage): void;
  onRetry(id: string): void;
  onDiscard(id: string): void;
  highlight?: string;
  onReact(message: HomeMessage, value: string): void;
  onEditStart?(message: HomeMessage): void;
  onEditEnd?(): void;
  onEdit?(message: HomeMessage, text: string): Promise<boolean>;
  onRetract?(message: HomeMessage): void;
}

export function WorkThreadView({
  thread,
  place,
  messages,
  pendingIds,
  hasMore = false,
  loadingMore = false,
  onLoadMore,
  people,
  members,
  me,
  strings,
  canSend,
  editing,
  focused,
  replyTo,
  onReplyTo,
  focusComposer,
  onClose,
  onStatus,
  onOwner,
  onSend,
  onCopyLink,
  onRetry,
  onDiscard,
  highlight,
  onReact,
  onEditStart,
  onEditEnd,
  onEdit,
  onRetract,
}: WorkThreadViewProps) {
  const { t, format } = strings;
  const root = thread.id;
  const rows = useMemo<TimelineRow[]>(() => {
    const view = threadMessages(messages, root);
    const list: TimelineRow[] = [];
    if (view.root) list.push({ kind: "message", key: view.root.id, message: view.root, head: true });
    if (view.replies.length > 0) list.push({ kind: "replies", key: `replies-${root}`, count: thread.replyCount });
    let previous: HomeMessage | undefined;
    for (const node of threadTree(view.replies, root)) {
      list.push({
        kind: "message",
        key: node.message.id,
        message: node.message,
        head: previous?.author !== node.message.author || node.parent !== undefined || node.depth > 1,
        depth: node.depth,
        parent: node.parent,
      });
      previous = node.message;
    }
    return list;
  }, [messages, root, thread.replyCount]);
  const owner = people.get(thread.owner);
  const now = useClock();
  const starter = people.get(thread.root.author)?.name ?? thread.root.author;
  const resolved = thread.status === "resolved";
  return (
    <section className={`hc-work-thread${resolved ? " resolved" : ""}`} aria-label={thread.title}>
      <header className="hc-wt-header">
        <div className="hc-wt-crumbs">
          <button type="button" className="hc-back" onClick={onClose} aria-label={t("thread.back")} title={t("thread.back")}>
            <HomeIcon name="back" size={16} />
            <span>{place}</span>
          </button>
          <span className="hc-wt-spacer" />
          <button
            type="button"
            className="hc-icon-button"
            aria-label={t("action.copyLink")}
            title={`${t("action.copyLink")}  C`}
            onClick={() => onCopyLink(thread.root)}
          >
            <HomeIcon name="link" size={16} />
          </button>
          <button
            type="button"
            className="hc-icon-button hc-wt-close"
            aria-label={t("thread.close")}
            title={t("thread.close")}
            onClick={onClose}
          >
            <HomeIcon name="close" size={16} />
          </button>
        </div>
        <h2 className="hc-wt-title selectable">{thread.title}</h2>
        <p className="hc-wt-sub">
          {format("thread.started", starter, relativeTime(thread.root.createdAt, now, strings), place)}
        </p>
        <div className="hc-wt-props">
          <Menu>
            <MenuButton className={`hc-prop hc-status-button ${thread.status}`} label={t("status.label")}>
              <HomeIcon name={resolved ? "statusResolved" : "statusOpen"} size={14} />
              <span>{t(resolved ? "status.resolved" : "status.open")}</span>
              <HomeIcon name="chevronDown" size={12} />
            </MenuButton>
            <MenuPopup side="bottom" align="start">
              <MenuItem onSelect={() => onStatus("open")} shortcut={resolved ? "E" : undefined}>
                {t("status.open")}
              </MenuItem>
              <MenuItem onSelect={() => onStatus("resolved")} shortcut={resolved ? undefined : "E"}>
                {t("status.resolved")}
              </MenuItem>
            </MenuPopup>
          </Menu>
          <Menu>
            <MenuButton className="hc-prop" label={t("owner.label")}>
              <Avatar participant={owner} size={16} />
              <span>{owner?.name ?? thread.owner}</span>
              <HomeIcon name="chevronDown" size={12} />
            </MenuButton>
            <MenuPopup side="bottom" align="start">
              {members.map((member, index) => (
                <Fragment key={member.id}>
                  {index > 0 && member.chief !== members[index - 1]!.chief && <MenuSeparator />}
                  <MenuItem onSelect={() => onOwner(member.id)}>
                    <span className="hc-owner-item">
                      <Avatar participant={member} size={16} />
                      <span>{member.id === me ? format("owner.me", member.name) : member.name}</span>
                    </span>
                  </MenuItem>
                </Fragment>
              ))}
            </MenuPopup>
          </Menu>
          <span className="hc-wt-count">
            {thread.replyCount === 1 ? t("thread.replies.one") : format("thread.replies.many", String(thread.replyCount))}
          </span>
          <span className="hc-wt-keys" aria-hidden="true">
            {t("thread.keys")}
          </span>
        </div>
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
        onReply={(message) => onReplyTo(message.id === root ? undefined : message)}
        onCopyLink={onCopyLink}
        highlight={highlight}
        focused={focused}
        pending={pendingIds}
        onRetry={onRetry}
        onDiscard={onDiscard}
        className="in-thread"
        start="top"
      />
      {hasMore && (
        <button type="button" className="hc-thread-more" disabled={loadingMore} onClick={onLoadMore}>
          {t("thread.more")}
        </button>
      )}
      <div className="hc-wt-compose">
        {replyTo && (
          <div className="hc-thread-replying">
            <span>{format("thread.replyingTo", people.get(replyTo.author)?.name ?? replyTo.author)}</span>
            <button
              type="button"
              className="hc-icon-button"
              aria-label={t("thread.cancelReply")}
              title={t("thread.cancelReply")}
              onClick={() => onReplyTo(undefined)}
            >
              <HomeIcon name="close" size={14} />
            </button>
          </div>
        )}
        <Composer
          key={`reply-${root}-${replyTo?.id ?? ""}-${focusComposer}`}
          strings={strings}
          placeholder={resolved ? t("composer.reopen") : t("composer.thread")}
          label={t("composer.thread")}
          disabled={!canSend}
          people={members.filter((m) => m.id !== me)}
          focusOnOpen={replyTo !== undefined || focusComposer > 0}
          quiet
          onSend={(text) => {
            onReplyTo(undefined);
            return onSend(text, replyTo?.id);
          }}
        />
      </div>
    </section>
  );
}
