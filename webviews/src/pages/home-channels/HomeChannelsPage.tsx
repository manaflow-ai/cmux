// The Home: on the left one list of every conversation, newest activity first; on the right the
// open conversation (header, timeline, composer). A thread opens in place under its root, its
// replies indented by depth, so the page works at the narrow dock width; "Focus" gives the thread
// the whole pane. A view over the Home owners (HomeChannelsStore); no business rules live here.
// View state only: the inline editor, the keyboard cursor (J/K), what the composer replies to,
// whether the thread is focused, the palette and the create popover.
import { useMemo, useState, useSyncExternalStore, type ReactNode } from "react";
import type { Strings } from "../shared/i18n";
import { AddChannel } from "./AddChannel";
import { Composer } from "./Composer";
import { ConversationAvatar } from "./ConversationAvatar";
import { HomeIcon } from "./icons";
import { Inbox } from "./Inbox";
import {
  channelIds,
  conversationName,
  lastEditable,
  mergeMessages,
  messageLink,
  others,
  inboxOrder,
  replyCount,
  threadMessages,
  threadOf,
  threadRows,
  timelineRows,
  withDraft,
  type OpenThread,
  type TimelineRow,
} from "./model";
import { chiefPresence } from "./presence";
import type { HomeChannelsStore } from "./store";
import { Switcher, type PaletteAction } from "./Switcher";
import { threadMeta, type ThreadMeta } from "./threads";
import { Timeline, type ThreadAction } from "./Timeline";
import type { HomeMessage, HomeParticipant } from "./types";
import { useHomeKeys } from "./useHomeKeys";

/** What the composer sends into: the open thread, as a reply to its root or to one reply. */
interface ReplyTarget {
  root: string;
  parent?: HomeMessage;
}

const CHIEF: HomeParticipant = { id: "agent_mux", kind: "agent", name: "Chief", chief: true };

export function HomeChannelsPage({
  store,
  strings,
  footer,
}: {
  store: HomeChannelsStore;
  strings: Strings;
  /** Shown at the bottom of the conversation list (the instance bar on a daemon). */
  footer?: ReactNode;
}) {
  const snap = useSyncExternalStore(store.subscribe, store.getSnapshot);
  const [palette, setPalette] = useState(false);
  const [addChannel, setAddChannel] = useState<Element | null>(null);
  // One inline editor at a time.
  const [editing, setEditing] = useState<string | undefined>();
  const [cursor, setCursor] = useState<string | undefined>();
  const [target, setTarget] = useState<ReplyTarget | undefined>();
  const [focus, setFocus] = useState(false);
  const [notice, setNotice] = useState<string | undefined>();
  const { t, format } = strings;
  const me = snap.me?.id;
  const open = snap.selected ? snap.conversations.get(snap.selected) : undefined;
  const people = useMemo(() => {
    const map = new Map<string, HomeParticipant>();
    for (const conversation of snap.conversations.values()) for (const p of conversation.participants) map.set(p.id, p);
    if (snap.me) map.set(snap.me.id, snap.me);
    return map;
  }, [snap.conversations, snap.me]);
  // The open thread: the owner's thread pages with the window's copies (newer edits, live replies).
  // While more pages follow, only window copies inside the loaded pages show, so no gap opens.
  const threadSource = useMemo(() => {
    const view = snap.threadView;
    if (!view) return snap.messages;
    const through = view.hasMore ? (view.messages.at(-1)?.seq ?? 0) : Number.MAX_SAFE_INTEGER;
    const window = snap.messages.filter((m) => m.seq <= through);
    return mergeMessages(view.messages, window, Number.MAX_SAFE_INTEGER);
  }, [snap.threadView, snap.messages]);
  const thread = useMemo<(OpenThread & { rootMessage?: HomeMessage }) | undefined>(() => {
    if (!snap.thread) return undefined;
    const found = threadMessages(threadSource, snap.thread);
    return {
      root: snap.thread,
      rootMessage: found.root,
      replies: found.replies,
      hasMore: snap.threadView?.hasMore ?? false,
      stats: snap.threadStats.get(snap.thread),
    };
  }, [snap.thread, threadSource, snap.threadView, snap.threadStats]);
  const pending = useMemo(
    () => snap.pending.filter((entry) => entry.conversation === snap.selected),
    [snap.pending, snap.selected],
  );
  const focused = focus && thread?.rootMessage !== undefined;
  const rows = useMemo<TimelineRow[]>(() => {
    if (focused && thread?.rootMessage)
      return [
        { kind: "message", key: thread.root, message: thread.rootMessage, head: true },
        ...threadRows(thread, pending),
      ];
    return withDraft(
      timelineRows(snap.messages, snap.unseen, me, snap.threadsSeen, snap.threadStats, thread, pending),
      snap.draft,
    );
  }, [focused, thread, pending, snap.messages, snap.unseen, me, snap.threadsSeen, snap.threadStats, snap.draft]);
  const mentionable = useMemo(() => others(open, me), [open, me]);
  // Everyone the Home knows but me, agents first (the Chief always): the members a new channel can have.
  const everyone = useMemo(() => {
    const list = [...people.values()].filter((p) => p.id !== me);
    if (!list.some((p) => p.chief)) list.push(CHIEF);
    return list.sort(
      (a, b) => Number(b.chief) - Number(a.chief) || Number(b.kind === "agent") - Number(a.kind === "agent"),
    );
  }, [people, me]);
  const online = snap.connection === "online";
  const channels = useMemo(() => channelIds(snap.conversations.values(), me), [snap.conversations, me]);
  const channel = open ? channels.has(open.id) : false;
  const name = open ? conversationName(open, me) : "";
  const place = channel ? `#${name}` : name;
  const meta = (root: HomeMessage): ThreadMeta => threadMeta(root, snap.threadStatus);
  const byId = useMemo(() => {
    const map = new Map<string, HomeMessage>();
    for (const message of threadSource) map.set(message.id, message);
    return map;
  }, [threadSource]);
  const messageKeys = rows.flatMap((row) => (row.kind === "message" ? [row.message.id] : []));
  const cursorMessage = cursor ? byId.get(cursor) : undefined;

  const select = (id: string) => {
    setEditing(undefined);
    setCursor(undefined);
    setTarget(undefined);
    setFocus(false);
    setNotice(undefined);
    void store.select(id);
  };
  const toggleThread = (root: string) => {
    if (snap.thread === root) {
      setFocus(false);
      setTarget(undefined);
      void store.openThread(undefined);
    } else {
      setTarget(undefined);
      void store.openThread(root);
    }
  };
  const focusComposer = () =>
    document.querySelector<HTMLElement>(".hc-pane .hc-composer-main [contenteditable='true']")?.focus();
  /** Reply to a message: a root (or a top-level message) starts or continues its thread; a reply
   * gets a nested reply. The thread opens in place and the composer takes the keyboard. */
  const reply = (message: HomeMessage) => {
    const root = threadOf(message) ?? message.id;
    if (snap.thread !== root) void store.openThread(root);
    setTarget(message.id === root ? { root } : { root, parent: message });
    queueMicrotask(focusComposer);
  };
  const resolve = (root: string) => {
    const resolving = snap.threadStatus.get(root) !== "resolved";
    store.toggleResolved(root);
    // A resolved thread folds away; reopening keeps what is open.
    if (resolving && snap.thread === root && !focused) {
      setTarget(undefined);
      void store.openThread(undefined);
    }
  };
  const copyLink = (message: HomeMessage) => {
    void navigator.clipboard?.writeText(messageLink(message.conversation, message.id));
    setNotice(t("notice.linkCopied"));
  };
  const threadAction = (root: string, action: ThreadAction) => {
    if (action === "reply") {
      const message = byId.get(root);
      if (message) reply(message);
    } else if (action === "focus") setFocus(true);
    else if (action === "resolve") resolve(root);
    else if (action === "close") toggleThread(root);
    else store.loadMoreReplies();
  };

  useHomeKeys({
    openSwitcher: () => setPalette(true),
    move: (delta, unreadOnly) => {
      const order = inboxOrder(snap.conversations.values());
      const n = order.length;
      const start = order.findIndex((c) => c.id === snap.selected);
      const base = start < 0 ? (delta > 0 ? -1 : n) : start;
      for (let step = 1; step <= n; step += 1) {
        const next = order[(((base + delta * step) % n) + n) % n];
        if (next && (!unreadOnly || next.unread > 0)) {
          select(next.id);
          return;
        }
      }
    },
    escape: () => {
      if (palette) setPalette(false);
      else if (editing) setEditing(undefined);
      else if (target) setTarget(undefined);
      else if (cursor) setCursor(undefined);
      else if (focused) setFocus(false);
      else if (snap.thread) void store.openThread(undefined);
      else return false;
      return true;
    },
    cursor: (delta) => {
      if (messageKeys.length === 0) return;
      const index = cursor ? messageKeys.indexOf(cursor) : -1;
      const next = index < 0 ? messageKeys.length - 1 : Math.min(Math.max(index + delta, 0), messageKeys.length - 1);
      setCursor(messageKeys[next]);
      setNotice(undefined);
    },
    reply: () => {
      if (cursorMessage) reply(cursorMessage);
      else if (thread?.rootMessage) reply(thread.rootMessage);
      else focusComposer();
    },
    toggleThread: () => {
      const root = cursorMessage ? (threadOf(cursorMessage) ?? cursorMessage.id) : snap.thread;
      if (root) toggleThread(root);
    },
    copyLink: () => {
      if (cursorMessage) copyLink(cursorMessage);
    },
    resolve: () => {
      const root = cursorMessage ? (threadOf(cursorMessage) ?? cursorMessage.id) : snap.thread;
      if (root && (snap.threadStats.has(root) || root === snap.thread)) resolve(root);
    },
  });

  // The draft's author shows the growing reply; a "typing" line for it would repeat that.
  const typingNames = snap.typing
    .filter((id) => id !== me && id !== snap.draft?.participant)
    .map((id) => people.get(id)?.name ?? id);
  const presence = open ? chiefPresence(open, me, snap.activity) : undefined;
  const targetMeta = target ? (byId.get(target.root) ? meta(byId.get(target.root)!) : undefined) : undefined;
  const sendRoot = target?.root ?? (focused ? snap.thread : undefined);
  const subtitle = (() => {
    if (!open) return "";
    if (channel) {
      const names = open.participants
        .filter((p) => p.id !== me)
        .map((p) => p.name.split(" ")[0])
        .slice(0, 4)
        .join(", ");
      return `${format("header.members", String(open.participants.length))} · ${names}`;
    }
    if (presence) return t(`chief.${presence.state}`);
    const other = open.participants.find((p) => p.id !== me);
    return other?.kind === "agent" ? t("agent.badge") : t("header.direct");
  })();
  const threadMetas = useMemo(
    () =>
      rows
        .flatMap((row) => (row.kind === "message" && row.thread ? [row.message] : []))
        .reverse()
        .map((root) => threadMeta(root, snap.threadStatus)),
    [rows, snap.threadStatus],
  );
  const paletteActions: PaletteAction[] = [
    ...(online
      ? [
          {
            id: "new-channel",
            title: t("rail.addChannel"),
            icon: "compose" as const,
            run: () => setAddChannel(document.querySelector(".hc-inbox-new") ?? document.body),
          },
        ]
      : []),
    ...(thread?.rootMessage && !focused
      ? [{ id: "focus", title: t("thread.focus"), icon: "expand" as const, run: () => setFocus(true) }]
      : []),
    ...(thread?.rootMessage
      ? [
          {
            id: "resolve",
            title: t(snap.threadStatus.get(thread.root) === "resolved" ? "thread.reopen" : "thread.resolve"),
            icon: "check" as const,
            key: "E",
            run: () => resolve(thread.root),
          },
        ]
      : []),
    ...(cursorMessage
      ? [{ id: "copy", title: t("action.copyLink"), icon: "link" as const, key: "C", run: () => copyLink(cursorMessage) }]
      : []),
  ];
  const empty = online && !snap.loading && snap.conversations.size === 0;

  return (
    <div className="hc-page">
      <Inbox
        conversations={snap.conversations}
        people={people}
        me={me}
        selected={snap.selected}
        activity={snap.activity}
        strings={strings}
        onSelect={select}
        onOpenPalette={() => setPalette(true)}
        onAddChannel={online ? (anchor) => setAddChannel(anchor) : undefined}
        footer={footer}
      />
      <section className={`hc-pane${focused ? " focused" : ""}`} aria-label={focused ? targetMeta?.title : place}>
        {empty ? (
          <div className="hc-empty">
            <h1>{t("empty.title")}</h1>
            <p>{t("empty.body")}</p>
            {online && (
              <button
                type="button"
                className="hc-text-button primary large"
                onClick={(event) => setAddChannel(event.currentTarget)}
              >
                {t("rail.addChannel")}
              </button>
            )}
          </div>
        ) : (
          <>
            <header className="hc-head">
              {focused && thread?.rootMessage ? (
                <>
                  <button type="button" className="hc-back" onClick={() => setFocus(false)}>
                    <HomeIcon name="chevronLeft" size={16} />
                    {place}
                  </button>
                  <div className="hc-head-text">
                    <h1 className="hc-head-title">{meta(thread.rootMessage).title}</h1>
                    <p className="hc-head-sub">
                      {[
                        t(meta(thread.rootMessage).status === "resolved" ? "thread.resolved" : "thread.open"),
                        format("thread.owner", people.get(meta(thread.rootMessage).owner)?.name ?? ""),
                        format("thread.replies.many", String(replyCount(thread.replies, thread.stats))),
                      ].join(" · ")}
                    </p>
                  </div>
                </>
              ) : (
                open && (
                  <>
                    <ConversationAvatar
                      conversation={open}
                      channel={channel}
                      me={me}
                      size={38}
                      presence={presence?.state}
                    />
                    <div className="hc-head-text">
                      <h1 className="hc-head-title">{place}</h1>
                      <p className={`hc-head-sub${presence ? ` ${presence.state}` : ""}`}>{subtitle}</p>
                    </div>
                  </>
                )
              )}
              {!online && (
                <output className="hc-connection">
                  {t(snap.connection === "connecting" ? "connection.connecting" : "connection.offline")}
                </output>
              )}
            </header>
            {snap.error && (
              <output className="hc-error selectable">
                <span>{snap.error}</span>
                <button type="button" onClick={() => store.dismissError()}>
                  {t("error.dismiss")}
                </button>
              </output>
            )}
            <Timeline
              conversation={focused ? `thread:${snap.thread}` : snap.selected}
              rows={rows}
              people={people}
              me={me}
              strings={strings}
              loadingOlder={snap.loadingOlder}
              onLoadOlder={() => (focused ? undefined : void store.loadOlder())}
              onOpenThread={toggleThread}
              onReply={reply}
              onReact={(message, value) => void store.react(message, value)}
              onCopyLink={copyLink}
              highlight={snap.highlight}
              editing={editing}
              onEditStart={(message) => setEditing(message.id)}
              onEditEnd={() => setEditing(undefined)}
              onEdit={(message, text) => store.edit(message, text)}
              onRetract={(message) => void store.retract(message)}
              selected={cursor}
              meta={meta}
              expanded={snap.thread}
              onAnswer={(message, partIndex, selections) => void store.answer(message, partIndex, selections)}
              onRetry={(key) => store.retry(key)}
              onDiscard={(key) => store.discard(key)}
              onThreadAction={threadAction}
              focused={focused}
              className={focused ? "in-focus" : undefined}
              empty={
                open && (
                  <div className="hc-intro">
                    <ConversationAvatar conversation={open} channel={channel} me={me} size={56} />
                    <h2>{format("intro.title", place)}</h2>
                    <p>{t(channel ? "intro.channel" : "intro.direct")}</p>
                  </div>
                )
              }
            />
            <div className="hc-typing" aria-live="polite">
              {notice ??
                (typingNames.length === 1
                  ? format("typing.one", typingNames[0]!)
                  : typingNames.length > 1
                    ? t("typing.many")
                    : "")}
            </div>
            {open && (
              <Composer
                key={open.id}
                strings={strings}
                className="hc-composer-main"
                placeholder={sendRoot ? t("composer.thread") : format("composer.placeholder", place)}
                label={sendRoot ? t("composer.thread") : format("composer.placeholder", name)}
                disabled={!online}
                people={mentionable}
                context={
                  target && (
                    <div className="hc-reply-context">
                      <HomeIcon name="reply" size={14} />
                      <span className="hc-reply-context-text">
                        {target.parent
                          ? format("composer.replyTo", people.get(target.parent.author)?.name ?? target.parent.author)
                          : format("composer.inThread", targetMeta?.title ?? "")}
                      </span>
                      <button
                        type="button"
                        className="hc-icon-button small"
                        aria-label={t("thread.cancelReply")}
                        title={t("thread.cancelReply")}
                        onClick={() => setTarget(undefined)}
                      >
                        <HomeIcon name="close" size={13} />
                      </button>
                    </div>
                  )
                }
                onEditLast={() => {
                  const last = lastEditable(snap.messages, me);
                  if (last) setEditing(last.id);
                }}
                onSend={(text) => store.send(text, sendRoot, target?.parent?.id)}
              />
            )}
          </>
        )}
      </section>
      {addChannel && (
        <AddChannel
          anchor={addChannel}
          people={everyone}
          strings={strings}
          onCreate={(title, participants) => store.createChannel(title, participants)}
          onClose={() => setAddChannel(null)}
        />
      )}
      {palette && (
        <Switcher
          conversations={snap.conversations}
          threads={threadMetas}
          actions={paletteActions}
          me={me}
          strings={strings}
          onPick={(id) => {
            setPalette(false);
            select(id);
          }}
          onPickThread={(root) => {
            setPalette(false);
            if (snap.thread !== root) void store.openThread(root);
            setCursor(root);
          }}
          onClose={() => setPalette(false)}
        />
      )}
    </div>
  );
}
