// The Channels view: the one chronological list on the start side; the open conversation (header,
// timeline, composer) on the other, with the thread sheet over the timeline. A view over the Home
// owners (HomeChannelsStore); no business rules live here. View state only: the palette, the
// create popover, the inline editor, the keyboard's current message and a short notice.
import { useMemo, useState, useSyncExternalStore } from "react";
import type { Strings } from "../shared/i18n";
import { AddChannel } from "./AddChannel";
import { Avatar, ChannelMark } from "./Avatar";
import { Composer } from "./Composer";
import { ConversationList, useStamp } from "./ConversationList";
import { HomeIcon } from "./icons";
import {
  activityAt,
  channelIds,
  chiefState,
  chronological,
  conversationName,
  lastEditable,
  mergeMessages,
  messageLink,
  others,
  pendingMessages,
  threadSummaries,
  timelineRows,
  withDraft,
} from "./model";
import { Palette, type PaletteItem } from "./Palette";
import type { HomeChannelsStore } from "./store";
import { threadObject, ThreadStatusBook } from "./threads";
import { ThreadSheet } from "./ThreadSheet";
import { Timeline } from "./Timeline";
import type { HomeMessage, HomeParticipant } from "./types";
import { useHomeKeys } from "./useHomeKeys";

const NOTICE_MS = 1600;

export function HomeChannelsPage({ store, strings }: { store: HomeChannelsStore; strings: Strings }) {
  const snap = useSyncExternalStore(store.subscribe, store.getSnapshot);
  const [book] = useState(() => new ThreadStatusBook());
  const statusVersion = useSyncExternalStore(book.subscribe, book.getVersion);
  const [palette, setPalette] = useState(false);
  const [addChannel, setAddChannel] = useState<Element | null>(null);
  const [editing, setEditing] = useState<{ id: string; surface: "main" | "thread" } | undefined>();
  const [focused, setFocused] = useState<string | undefined>();
  const [notice, setNotice] = useState<string | undefined>();
  const { t, format } = strings;
  const stamp = useStamp(strings.language);
  const me = snap.me?.id;
  const open = snap.selected ? snap.conversations.get(snap.selected) : undefined;
  const pendingByKey = useMemo(() => new Map(snap.pending.map((entry) => [entry.key, entry])), [snap.pending]);
  const pendingState = (key: string) => {
    const entry = pendingByKey.get(key);
    return entry ? (entry.failed ? "failed" : "sending") : undefined;
  };
  // The window plus my sends the owner has not shown yet, after its newest message.
  const shown = useMemo(
    () => [...snap.messages, ...pendingMessages(snap.pending, snap.selected, me, snap.messages.at(-1)?.seq ?? 0)],
    [snap.messages, snap.pending, snap.selected, me],
  );
  const rows = useMemo(
    () => withDraft(timelineRows(shown, snap.unseen, me, snap.threadsSeen, snap.threadStats), snap.draft),
    [shown, snap.unseen, me, snap.threadsSeen, snap.threadStats, snap.draft],
  );
  // The open thread: the owner's thread pages with the window's copies (newer edits, live replies).
  const threadSource = useMemo(() => {
    const view = snap.threadView;
    if (!view) return shown;
    const through = view.hasMore ? (view.messages.at(-1)?.seq ?? 0) : Number.MAX_SAFE_INTEGER;
    const window = shown.filter((m) => m.seq <= through || m.id.startsWith("pending:"));
    return mergeMessages(view.messages, window, Number.MAX_SAFE_INTEGER);
  }, [snap.threadView, shown]);
  const people = useMemo(() => {
    const map = new Map<string, HomeParticipant>();
    for (const conversation of snap.conversations.values()) for (const p of conversation.participants) map.set(p.id, p);
    if (snap.me) map.set(snap.me.id, snap.me);
    return map;
  }, [snap.conversations, snap.me]);
  const mentionable = useMemo(() => others(open, me), [open, me]);
  const everyone = useMemo(
    () =>
      [...people.values()]
        .filter((p) => p.id !== me)
        .sort((a, b) => Number(b.chief) - Number(a.chief) || Number(b.kind === "agent") - Number(a.kind === "agent")),
    [people, me],
  );
  const channels = useMemo(() => channelIds(snap.conversations.values(), me), [snap.conversations, me]);
  const online = snap.connection === "online";
  const name = open ? conversationName(open, me) : "";
  const channel = open ? channels.has(open.id) : false;
  const place = channel ? `#${name}` : name;
  const state = open && !channel ? chiefState(open, me, snap.activity.get(open.id)) : undefined;
  // Threads of the open conversation (loaded roots), with their objects.
  const threads = useMemo(() => {
    void statusVersion;
    const summaries = threadSummaries(shown, snap.unseen, me, snap.threadsSeen, snap.threadStats);
    return shown
      .filter((m) => summaries.has(m.id))
      .map((m) => ({ object: threadObject(m, book.status(m.id)), summary: summaries.get(m.id)!, root: m }))
      .reverse();
  }, [shown, snap.unseen, me, snap.threadsSeen, snap.threadStats, book, statusVersion]);
  const openThreads = threads.filter((entry) => entry.object.status === "open").length;
  const sheetRoot = snap.thread ? threadSource.find((m) => m.id === snap.thread) : undefined;
  const sheetThread = sheetRoot ? threadObject(sheetRoot, book.status(sheetRoot.id)) : undefined;
  // What j/k walk: the timeline's messages and thread rows (not my pending sends).
  const walk = useMemo(
    () =>
      rows.flatMap((row) => (row.kind === "message" && !row.message.id.startsWith("pending:") ? [row.message] : [])),
    [rows],
  );
  const typingNames = snap.typing
    .filter((id) => id !== me && id !== snap.draft?.participant)
    .map((id) => people.get(id)?.name ?? id);

  const say = (text: string) => {
    setNotice(text);
    window.setTimeout(() => setNotice((current) => (current === text ? undefined : current)), NOTICE_MS);
  };
  const copyLink = (message?: HomeMessage) => {
    if (!snap.selected) return;
    void navigator.clipboard?.writeText(messageLink(snap.selected, message?.id));
    say(t("notice.linkCopied"));
  };
  const select = (id: string) => {
    setEditing(undefined);
    setFocused(undefined);
    void store.select(id);
  };
  const openThread = (root: string | undefined) => {
    setEditing(undefined);
    void store.openThread(root);
  };
  const focusComposer = (scope: string) =>
    window.requestAnimationFrame(() =>
      document.querySelector<HTMLElement>(`${scope} [contenteditable="true"], ${scope} textarea`)?.focus(),
    );
  const toggleStatus = (root: string) => {
    book.toggle(root);
    say(t(book.status(root) === "resolved" ? "notice.resolved" : "notice.reopened"));
  };
  const focusedMessage = focused ? walk.find((m) => m.id === focused) : undefined;
  const moveList = (delta: 1 | -1, unreadOnly: boolean) => {
    const order = chronological(snap.conversations.values());
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
  };
  useHomeKeys({
    openPalette: () => setPalette(true),
    move: moveList,
    escape: () => {
      if (palette) setPalette(false);
      else if (editing) setEditing(undefined);
      else if (snap.thread) openThread(undefined);
      else if (focused) setFocused(undefined);
      else return false;
      return true;
    },
    step: (delta) => {
      if (walk.length === 0) return;
      const index = walk.findIndex((m) => m.id === focused);
      const next = index < 0 ? walk.length - 1 : Math.min(Math.max(index + delta, 0), walk.length - 1);
      setFocused(walk[next]!.id);
    },
    reply: () => {
      if (focusedMessage) {
        if (snap.thread !== focusedMessage.id) openThread(focusedMessage.id);
        focusComposer(".lg-sheet");
      } else if (snap.thread) focusComposer(".lg-sheet");
      else focusComposer(".lg-main-compose");
    },
    thread: () => {
      const target = focusedMessage?.id ?? snap.thread;
      if (target) openThread(snap.thread === target ? undefined : target);
    },
    copyLink: () => copyLink(focusedMessage ?? sheetRoot),
    resolve: () => {
      const target = snap.thread ?? (focusedMessage && threads.some((x) => x.root.id === focusedMessage.id) ? focusedMessage.id : undefined);
      if (target) toggleStatus(target);
    },
  });
  const editActions = (surface: "main" | "thread") => ({
    editing: editing?.surface === surface ? editing.id : undefined,
    onEditStart: (message: HomeMessage) => setEditing({ id: message.id, surface }),
    onEditEnd: () => setEditing(undefined),
    onEdit: (message: HomeMessage, text: string) => store.edit(message, text),
    onRetract: (message: HomeMessage) => void store.retract(message),
  });

  const paletteItems = useMemo<PaletteItem[]>(() => {
    const items: PaletteItem[] = [];
    for (const c of chronological(snap.conversations.values())) {
      const isChannel = channels.has(c.id);
      const other = c.participants.find((p) => p.id !== me);
      const title = conversationName(c, me);
      items.push({
        id: `c:${c.id}`,
        group: "conversations",
        title: isChannel ? `#${title}` : title,
        keywords: c.participants.map((p) => p.name),
        meta: stamp(activityAt(c)),
        mark: isChannel ? <ChannelMark size={16} /> : <Avatar participant={other} size={16} />,
        run: () => select(c.id),
      });
    }
    for (const entry of threads) {
      items.push({
        id: `t:${entry.root.id}`,
        group: "threads",
        title: entry.object.title,
        meta: `${t(entry.object.status === "open" ? "thread.status.open" : "thread.status.resolved")} · ${
          entry.summary.count === 1 ? t("thread.replies.one") : format("thread.replies.many", String(entry.summary.count))
        }`,
        mark: <span className={`lg-status ${entry.object.status}`} />,
        run: () => openThread(entry.root.id),
      });
    }
    if (online && everyone.length > 0)
      items.push({
        id: "a:new-channel",
        group: "actions",
        title: t("rail.addChannel"),
        mark: <HomeIcon name="plus" size={16} />,
        run: () => setAddChannel(document.querySelector(".lg-list-header .hc-icon-button") ?? document.body),
      });
    if (snap.thread)
      items.push({
        id: "a:resolve",
        group: "actions",
        title: t(sheetThread?.status === "resolved" ? "thread.reopen" : "thread.resolve"),
        mark: <HomeIcon name="check" size={16} />,
        shortcut: "E",
        run: () => snap.thread && toggleStatus(snap.thread),
      });
    if (snap.selected)
      items.push({
        id: "a:copy-conversation",
        group: "actions",
        title: t("action.copyConversationLink"),
        mark: <HomeIcon name="link" size={16} />,
        run: () => copyLink(),
      });
    items.push({
      id: "a:next-unread",
      group: "actions",
      title: t("action.nextUnread"),
      mark: <HomeIcon name="chevronRight" size={16} />,
      shortcut: "⌥⇧↓",
      run: () => moveList(1, true),
    });
    return items;
    // The actions close over the latest render; the list is rebuilt when its inputs change.
    // oxlint-disable-next-line react-hooks/exhaustive-deps
  }, [snap.conversations, channels, me, threads, online, everyone, snap.thread, snap.selected, sheetThread?.status, stamp]);

  const empty = snap.conversations.size === 0 && !snap.loading;
  return (
    <div className="lg-page">
      <ConversationList
        conversations={snap.conversations}
        channels={channels}
        people={people}
        activity={snap.activity}
        me={me}
        selected={snap.selected}
        strings={strings}
        onSelect={select}
        onOpenPalette={() => setPalette(true)}
        onAddChannel={online && everyone.length > 0 ? (anchor) => setAddChannel(anchor) : undefined}
      />
      <section className={`lg-main${snap.thread ? " with-sheet" : ""}`} aria-label={place || t("page.title")}>
        {snap.loading ? null : empty || !open ? (
          <EmptyState
            strings={strings}
            noConversations={empty}
            canCreate={online && everyone.length > 0}
            onCreate={(anchor) => setAddChannel(anchor)}
            onPalette={() => setPalette(true)}
          />
        ) : (
          <>
            <header className="lg-header">
              <span className="lg-header-mark">
                {channel ? (
                  <ChannelMark />
                ) : (
                  <Avatar participant={open.participants.find((p) => p.id !== me)} size={20} state={state} />
                )}
              </span>
              <h1 className="lg-header-title">{name}</h1>
              <p className="lg-header-context">
                {state && state !== "idle" ? (
                  <span className={`lg-state ${state}`}>
                    {t(state === "working" ? "chief.working" : "chief.waiting")}
                  </span>
                ) : state === "idle" ? (
                  <span>{t("chief.idle")}</span>
                ) : null}
                {channel && <span>{format("header.members", String(open.participants.length))}</span>}
                {channel && threads.length > 0 && (
                  <span>
                    {openThreads === 1 ? t("header.openThread.one") : format("header.openThreads", String(openThreads))}
                  </span>
                )}
              </p>
              <span className="lg-spacer" />
              {!online && (
                <output className="lg-connection">
                  {t(snap.connection === "connecting" ? "connection.connecting" : "connection.offline")}
                </output>
              )}
              {notice && <output className="lg-notice">{notice}</output>}
              {channel && (
                <span className="lg-faces" aria-hidden="true">
                  {open.participants.slice(0, 4).map((p) => (
                    <Avatar key={p.id} participant={p} size={20} />
                  ))}
                </span>
              )}
              <button
                type="button"
                className="hc-icon-button"
                aria-label={t("action.copyConversationLink")}
                title={t("action.copyConversationLink")}
                onClick={() => copyLink()}
              >
                <HomeIcon name="link" size={16} />
              </button>
            </header>
            {snap.error && (
              <output className="hc-error selectable">
                <span>{snap.error}</span>
                <button type="button" onClick={() => store.dismissError()}>
                  {t("error.dismiss")}
                </button>
              </output>
            )}
            <div className="lg-stage">
              <Timeline
                conversation={snap.selected}
                rows={rows}
                people={people}
                me={me}
                strings={strings}
                loadingOlder={snap.loadingOlder}
                onLoadOlder={() => void store.loadOlder()}
                onOpenThread={(root) => openThread(root)}
                onReact={(message, value) => void store.react(message, value)}
                onCopyLink={(message) => copyLink(message)}
                highlight={snap.highlight}
                threadFor={(root) => threadObject(root, book.status(root.id))}
                openThread={snap.thread}
                focused={focused}
                pendingState={pendingState}
                onRetry={(key) => store.retry(key)}
                onDiscard={(key) => store.discard(key)}
                stamp={stamp}
                empty={t("timeline.empty")}
                {...editActions("main")}
              />
              <div className="lg-typing" aria-live="polite">
                {typingNames.length === 1
                  ? format("typing.one", typingNames[0]!)
                  : typingNames.length > 1
                    ? t("typing.many")
                    : ""}
              </div>
              <div className="lg-main-compose">
                <Composer
                  key={open.id}
                  strings={strings}
                  placeholder={format("composer.placeholder", place)}
                  label={format("composer.placeholder", name)}
                  disabled={!online}
                  people={mentionable}
                  onEditLast={() => {
                    const last = lastEditable(snap.messages, me);
                    if (last) setEditing({ id: last.id, surface: "main" });
                  }}
                  onSend={(text) => store.send(text)}
                />
              </div>
              {snap.thread && (
                <ThreadSheet
                  key={snap.thread}
                  root={snap.thread}
                  thread={sheetThread}
                  place={place}
                  messages={threadSource}
                  stats={snap.threadStats.get(snap.thread)}
                  hasMore={snap.threadView?.hasMore}
                  loadingMore={snap.threadView?.loading}
                  onLoadMore={() => store.loadMoreReplies()}
                  people={people}
                  mentionable={mentionable}
                  me={me}
                  strings={strings}
                  canSend={online}
                  highlight={snap.highlight}
                  onClose={() => openThread(undefined)}
                  onToggleStatus={() => snap.thread && toggleStatus(snap.thread)}
                  onSend={(text, parent) => store.send(text, snap.thread, parent)}
                  onCopyLink={(message) => copyLink(message)}
                  onReact={(message, value) => void store.react(message, value)}
                  pendingState={pendingState}
                  onRetry={(key) => store.retry(key)}
                  onDiscard={(key) => store.discard(key)}
                  {...editActions("thread")}
                />
              )}
            </div>
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
      {palette && <Palette items={paletteItems} strings={strings} onClose={() => setPalette(false)} />}
    </div>
  );
}

function EmptyState({
  strings,
  noConversations,
  canCreate,
  onCreate,
  onPalette,
}: {
  strings: Strings;
  noConversations: boolean;
  canCreate: boolean;
  onCreate(anchor: Element): void;
  onPalette(): void;
}) {
  const { t } = strings;
  return (
    <div className="lg-empty">
      <h1 className="lg-empty-title">{t(noConversations ? "empty.title" : "empty.pick.title")}</h1>
      <p className="lg-empty-body">{t(noConversations ? "empty.body" : "empty.pick.body")}</p>
      <div className="lg-empty-actions">
        {noConversations && canCreate && (
          <button type="button" className="lg-button primary" onClick={(event) => onCreate(event.currentTarget)}>
            {t("rail.addChannel")}
          </button>
        )}
        <button type="button" className="lg-button" onClick={onPalette}>
          <span>{t("rail.jump")}</span>
          <kbd className="lg-kbd">⌘K</kbd>
        </button>
      </div>
    </div>
  );
}
