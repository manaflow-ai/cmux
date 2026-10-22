// The thread sheet: slides in from the end edge over the timeline (not a third column, so the
// page works at the Home dock width). A thread is an object: the header shows its status (press
// it or E to resolve or reopen), where it lives, its title (press it to rename; an empty title
// shows the root's first line again) and one muted line (owner, which opens a menu of the
// participants; replies; people). Then the root, the replies in tree order with depth rails
// (capped at 4 indents), and a reply composer; Reply on any reply nests under it. Escape closes
// the sheet (or the title field first).
import { useMemo, useRef, useState } from "react";
import { KeyboardScope } from "../../ui/KeyboardScope";
import { Menu, MenuButton, MenuItem, MenuPopup, MenuSeparator } from "../../ui/Menu";
import type { Strings } from "../shared/i18n";
import { Composer, type ComposerProps } from "./Composer";
import { HomeIcon } from "./icons";
import { replyCount, threadMessages, threadTree, type TimelineRow } from "./model";
import type { ThreadObject } from "./threads";
import { Timeline } from "./Timeline";
import type { HomeAttachment, HomeMessage, HomeParticipant, HomeThreadStats } from "./types";

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
  /** Who can own the thread (the conversation's participants). */
  owners: readonly HomeParticipant[];
  /** Sets the owner; "" clears it. */
  onSetOwner(owner: string): void;
  /** Sets the title; "" clears it. Resolves true when the owner took it. */
  onRename(title: string): Promise<boolean>;
  onSend(text: string, parent?: string, attachments?: readonly HomeAttachment[]): Promise<boolean>;
  /** Files upload through this (absent: no attach in the thread composer). */
  attachments?: ComposerProps["attachments"];
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
  owners,
  onSetOwner,
  onRename,
  onSend,
  attachments,
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
  /** Files dropped on the sheet go to the thread's composer (not the conversation's). */
  const sheet = useRef<HTMLElement | null>(null);
  const { t, format } = strings;
  const [replyTo, setReplyTo] = useState<HomeMessage | undefined>();
  const [renaming, setRenaming] = useState<string | undefined>();
  /** Enter or Escape ended the edit: the blur that follows (or an unmount) saves nothing. */
  const closing = useRef(false);
  const [ownerMenu, setOwnerMenu] = useState(false);
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
  const owner = thread?.owner ? (people.get(thread.owner)?.name ?? thread.owner) : undefined;
  const startRename = () => {
    closing.current = false;
    setRenaming(thread?.title ?? "");
  };
  const saveTitle = (value: string) => {
    if (closing.current) return;
    closing.current = true;
    const next = value.trim();
    // Unchanged (or the derived title kept as it was): nothing to send.
    if (!thread || next === thread.title) return setRenaming(undefined);
    void onRename(next).then((done) => {
      if (done) setRenaming(undefined);
      else closing.current = false;
    });
  };
  const resolved = thread?.status === "resolved";
  return (
    <aside
      ref={sheet}
      className="lg-sheet"
      data-drop-zone
      data-status={thread?.status ?? "open"}
      aria-label={thread?.title || t("thread.title")}
    >
      <header className="lg-sheet-header">
        <div className="lg-sheet-bar">
          <button
            type="button"
            className={`lg-status-button${resolved ? " resolved" : ""}`}
            onClick={onToggleStatus}
            /* tooltip-allow: the button shows the status; the tooltip names what a click does */
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
          <button type="button" className="hc-icon-button" aria-label={t("thread.close")} onClick={onClose}>
            <HomeIcon name="close" size={16} />
          </button>
        </div>
        {renaming !== undefined ? (
          <KeyboardScope
            handleKeyDown={(event) => {
              if (event.key === "Enter") {
                event.preventDefault();
                saveTitle(renaming);
              } else if (event.key === "Escape") {
                event.preventDefault();
                event.stopPropagation();
                closing.current = true;
                setRenaming(undefined);
              }
            }}
          >
            <input
              className="lg-sheet-title-field"
              aria-label={t("thread.rename")}
              value={renaming}
              maxLength={200}
              // The field opens from a press on the title: it takes the keyboard at once.
              // oxlint-disable-next-line jsx-a11y/no-autofocus
              autoFocus
              onChange={(event) => setRenaming(event.target.value)}
              onBlur={() => saveTitle(renaming)}
            />
          </KeyboardScope>
        ) : (
          <h2 className="lg-sheet-title">
            <button
              type="button"
              className="lg-sheet-title-button"
              /* tooltip-allow: the button shows the title; the tooltip says a click renames it */
              title={t("thread.rename")}
              disabled={!thread}
              onClick={startRename}
            >
              {thread?.title || t("thread.title")}
            </button>
          </h2>
        )}
        <p className="lg-sheet-meta">
          <Menu open={ownerMenu} onOpenChange={setOwnerMenu}>
            <MenuButton
              className="lg-owner-button"
              label={`${owner ? format("thread.owner", owner) : t("thread.noOwner")}, ${t("thread.setOwner")}`}
              title={t("thread.setOwner")}
            >
              {owner ? format("thread.owner", owner) : t("thread.noOwner")}
            </MenuButton>
            <MenuPopup side="bottom" align="start">
              {owners.map((participant) => (
                <MenuItem key={participant.id} onSelect={() => onSetOwner(participant.id)}>
                  {participant.name}
                </MenuItem>
              ))}
              {thread?.owner && <MenuSeparator />}
              {thread?.owner && <MenuItem onSelect={() => onSetOwner("")}>{t("thread.noOwner")}</MenuItem>}
            </MenuPopup>
          </Menu>
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
          attachments={attachments}
          dropZone={sheet}
          onSend={async (text, files) => {
            const sent = await onSend(text, replyTo?.id, files);
            if (sent) setReplyTo(undefined);
            return sent;
          }}
        />
      </div>
    </aside>
  );
}
