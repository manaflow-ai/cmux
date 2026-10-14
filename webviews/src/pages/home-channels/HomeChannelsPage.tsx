// The Channels Home, "threads as work": the conversation list on the left; on the right the open
// conversation with two views, Threads (its threads as work items: title, status, owner, grouped
// Open and Resolved; the default for channels) and Timeline (every message in order; the default
// for direct conversations); an open thread shows full height beside it (or in its place at the
// dock width). A view over the Home owners (HomeChannelsStore); no business rules live here.
// View state only: the view per conversation, the threads filter, the keyboard's row, which message
// edits inline, the palette.
import { useMemo, useState, useSyncExternalStore } from "react";
import type { Strings } from "../shared/i18n";
import { AddChannel } from "./AddChannel";
import { Avatar } from "./Avatar";
import { chiefState } from "./chiefState";
import { Composer } from "./Composer";
import { ConversationList } from "./ConversationList";
import { HomeIcon } from "./icons";
import {
  channelIds,
  conversationName,
  lastEditable,
  mergeMessages,
  messageLink,
  others,
  threadMessages,
  threadOf,
  threadSummaries,
  threadTree,
  timelineRows,
  withDraft,
} from "./model";
import { Palette, type PaletteItem } from "./Palette";
import type { HomeChannelsStore } from "./store";
import { matchesFilter, ThreadsList } from "./ThreadsList";
import { workThread, workThreads, type ThreadFilter, type WorkThread } from "./threads";
import { Timeline } from "./Timeline";
import type { HomeMessage, HomeParticipant } from "./types";
import { useHomeKeys, type WorkKey } from "./useHomeKeys";
import { WorkThreadView } from "./WorkThreadView";

type View = "threads" | "timeline";

export function HomeChannelsPage({ store, strings }: { store: HomeChannelsStore; strings: Strings }) {
  const snap = useSyncExternalStore(store.subscribe, store.getSnapshot);
  const [palette, setPalette] = useState(false);
  const [addChannel, setAddChannel] = useState<Element | null>(null);
  const [editing, setEditing] = useState<{ id: string; surface: "main" | "thread" } | undefined>();
  const [views, setViews] = useState<ReadonlyMap<string, View>>(new Map());
  const [filter, setFilter] = useState<ThreadFilter>("all");
  const [focus, setFocus] = useState<string | undefined>();
  const [replyTo, setReplyTo] = useState<HomeMessage | undefined>();
  const [composerFocus, setComposerFocus] = useState(0);
  const [toast, setToast] = useState<string | undefined>();
  const { t, format } = strings;
  const me = snap.me?.id;
  const open = snap.selected ? snap.conversations.get(snap.selected) : undefined;
  const channels = useMemo(() => channelIds(snap.conversations.values(), me), [snap.conversations, me]);
  const channel = open ? channels.has(open.id) : false;
  const view: View = (open && views.get(open.id)) ?? (channel ? "threads" : "timeline");
  const name = open ? conversationName(open, me) : "";
  const place = channel ? `#${name}` : name;
  const online = snap.connection === "online";

  // My sends the owner has not shown yet, in this conversation.
  const pending = useMemo(
    () => snap.pending.filter((p) => p.message.conversation === snap.selected),
    [snap.pending, snap.selected],
  );
  const pendingIds = useMemo(() => new Map(pending.map((p) => [p.message.id, p.state])), [pending]);
  const windowMessages = useMemo(
    () => (pending.length ? [...snap.messages, ...pending.map((p) => p.message)] : snap.messages),
    [snap.messages, pending],
  );
  const rows = useMemo(
    () => withDraft(timelineRows(windowMessages, snap.unseen, me, snap.threadsSeen, snap.threadStats), snap.draft),
    [windowMessages, snap.unseen, me, snap.threadsSeen, snap.threadStats, snap.draft],
  );
  const summaries = useMemo(
    () => threadSummaries(snap.messages, snap.unseen, me, snap.threadsSeen, snap.threadStats),
    [snap.messages, snap.unseen, me, snap.threadsSeen, snap.threadStats],
  );
  const threads = useMemo(() => {
    const started = new Set(snap.startedThreads);
    const list = workThreads(windowMessages, summaries, snap.threadEdits);
    // A message started as a thread (the Threads view's composer) is a thread before any reply.
    for (const message of windowMessages) {
      if (started.has(message.clientMessageId ?? "") && !list.some((x) => x.id === message.id) && !threadOf(message))
        list.unshift(workThread(message, summaries.get(message.id), snap.threadEdits.get(message.id)));
    }
    return list;
  }, [windowMessages, summaries, snap.threadEdits, snap.startedThreads]);
  const looseCount = useMemo(
    () => snap.messages.filter((m) => !threadOf(m) && !summaries.has(m.id)).length,
    [snap.messages, summaries],
  );
  // The open thread: the owner's thread pages with the window's copies and my pending replies.
  const threadSource = useMemo(() => {
    const viewData = snap.threadView;
    const extra = pending.map((p) => p.message);
    if (!viewData) return [...snap.messages, ...extra];
    const through = viewData.hasMore ? (viewData.messages.at(-1)?.seq ?? 0) : Number.MAX_SAFE_INTEGER;
    const window = snap.messages.filter((m) => m.seq <= through);
    return [...mergeMessages(viewData.messages, window, Number.MAX_SAFE_INTEGER), ...extra];
  }, [snap.threadView, snap.messages, pending]);
  const openThread: WorkThread | undefined = useMemo(() => {
    if (!snap.thread) return undefined;
    const root = threadSource.find((m) => m.id === snap.thread);
    if (!root) return undefined;
    const thread = workThread(root, summaries.get(root.id), snap.threadEdits.get(root.id));
    const replies = threadSource.filter((m) => threadOf(m) === root.id && !m.retracted);
    return { ...thread, replyCount: Math.max(thread.replyCount, replies.length) };
  }, [snap.thread, threadSource, summaries, snap.threadEdits]);
  const people = useMemo(() => {
    const map = new Map<string, HomeParticipant>();
    for (const conversation of snap.conversations.values()) for (const p of conversation.participants) map.set(p.id, p);
    if (snap.me) map.set(snap.me.id, snap.me);
    return map;
  }, [snap.conversations, snap.me]);
  const mentionable = useMemo(() => others(open, me), [open, me]);
  // Who can own a thread here: me, then people, then agents and Chiefs.
  const members = useMemo(
    () =>
      [...(open?.participants ?? [])].sort(
        (a, b) =>
          Number(b.id === me) - Number(a.id === me) ||
          Number(a.kind === "agent") - Number(b.kind === "agent") ||
          Number(a.chief) - Number(b.chief),
      ),
    [open, me],
  );
  const everyone = useMemo(
    () =>
      [...people.values()]
        .filter((p) => p.id !== me)
        .sort((a, b) => Number(b.chief) - Number(a.chief) || Number(b.kind === "agent") - Number(a.kind === "agent")),
    [people, me],
  );
  const [showResolved, setShowResolved] = useState(false);
  // The rows the keyboard walks, in the order they show.
  const visibleThreads = useMemo(() => {
    const shown = threads.filter((x) => matchesFilter(x, filter, me, people));
    return [...shown.filter((x) => x.status === "open"), ...(showResolved ? shown.filter((x) => x.status === "resolved") : [])];
  }, [threads, filter, me, people, showResolved]);
  const threadOrder = useMemo(() => {
    if (!snap.thread) return [];
    const data = threadMessages(threadSource, snap.thread);
    return [...(data.root ? [data.root] : []), ...threadTree(data.replies, snap.thread).map((n) => n.message)];
  }, [snap.thread, threadSource]);
  const timelineOrder = useMemo(
    () => rows.flatMap((row) => (row.kind === "message" ? [row.message] : [])),
    [rows],
  );

  const flash = (text: string) => {
    setToast(text);
    setTimeout(() => setToast((current) => (current === text ? undefined : current)), 1600);
  };
  const copyLink = (message: HomeMessage) => {
    void navigator.clipboard?.writeText(messageLink(message.conversation, message.id));
    flash(t("toast.linkCopied"));
  };
  const select = (id: string) => {
    setEditing(undefined);
    setFocus(undefined);
    setReplyTo(undefined);
    void store.select(id);
  };
  const openThreadId = (id: string | undefined) => {
    setReplyTo(undefined);
    setFocus(undefined);
    void store.openThread(id);
  };
  const setView = (next: View) => {
    if (!open) return;
    setFocus(undefined);
    setViews((current) => new Map(current).set(open.id, next));
  };
  const toggleStatus = (thread: WorkThread | undefined) => {
    if (!thread) return;
    const next = thread.status === "open" ? "resolved" : "open";
    store.setThreadStatus(thread.id, next);
    flash(t(next === "resolved" ? "toast.resolved" : "toast.reopened"));
  };

  const work = (key: WorkKey): boolean => {
    const surface = snap.thread ? "thread" : view === "threads" && channel ? "threads" : "timeline";
    const ids =
      surface === "thread"
        ? threadOrder.map((m) => m.id)
        : surface === "threads"
          ? visibleThreads.map((x) => x.id)
          : timelineOrder.map((m) => m.id);
    const index = focus ? ids.indexOf(focus) : -1;
    const current = index >= 0 ? ids[index] : undefined;
    const message = (id: string | undefined) =>
      id ? [...threadSource, ...windowMessages].find((m) => m.id === id) : undefined;
    switch (key) {
      case "j":
      case "k": {
        if (ids.length === 0) return false;
        const start = index < 0 ? (key === "j" ? -1 : surface === "threads" ? -1 : ids.length) : index;
        const next = Math.min(ids.length - 1, Math.max(0, start + (key === "j" ? 1 : -1)));
        setFocus(ids[next]);
        return true;
      }
      case "enter":
      case "t":
        if (surface === "thread" || !current) return false;
        openThreadId(current);
        return true;
      case "r":
        if (surface === "thread") {
          const target = message(current);
          setReplyTo(target && target.id !== snap.thread ? target : undefined);
          setComposerFocus((n) => n + 1);
          return true;
        }
        if (!current) return false;
        openThreadId(current);
        setComposerFocus((n) => n + 1);
        return true;
      case "c": {
        const target = message(current) ?? (openThread ? openThread.root : undefined);
        if (!target) return false;
        copyLink(target);
        return true;
      }
      case "e":
        if (openThread) toggleStatus(openThread);
        else if (surface === "threads" && current) toggleStatus(threads.find((x) => x.id === current));
        else return false;
        return true;
    }
  };

  useHomeKeys({
    openSwitcher: () => setPalette(true),
    move: (delta, unreadOnly) => {
      const order = [...snap.conversations.values()].sort((a, b) => b.updatedAt - a.updatedAt);
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
      else if (replyTo) setReplyTo(undefined);
      else if (snap.thread) openThreadId(undefined);
      else if (focus) setFocus(undefined);
      else return false;
      return true;
    },
    work,
  });

  const typingNames = snap.typing
    .filter((id) => id !== me && id !== snap.draft?.participant)
    .map((id) => people.get(id)?.name ?? id);
  const editActions = (surface: "main" | "thread") => ({
    editing: editing?.surface === surface ? editing.id : undefined,
    onEditStart: (message: HomeMessage) => setEditing({ id: message.id, surface }),
    onEditEnd: () => setEditing(undefined),
    onEdit: (message: HomeMessage, text: string) => store.edit(message, text),
    onRetract: (message: HomeMessage) => void store.retract(message),
  });

  const state = open ? chiefState(open, me, snap.busy) : undefined;
  const openCount = threads.filter((x) => x.status === "open").length;
  const subtitle = !open
    ? ""
    : state?.kind === "working"
      ? snap.conversations.get(state.conversation)?.kind === "group"
        ? format("chief.workingIn", `#${conversationName(snap.conversations.get(state.conversation)!, me)}`)
        : t("chief.working")
      : state?.kind === "waiting"
        ? t("chief.waiting")
        : state
          ? t("chief.idle")
          : channel
            ? format("header.channelSummary", String(open.participants.length), String(openCount))
            : open.participants.find((p) => p.id !== me)?.kind === "agent"
              ? t("header.agent")
              : t("header.direct");

  const paletteItems = useMemo<PaletteItem[]>(() => {
    const items: PaletteItem[] = [];
    if (openThread) {
      items.push({
        id: "a:status",
        section: "action",
        title: t(openThread.status === "open" ? "palette.resolve" : "palette.reopen"),
        detail: "E",
        icon: openThread.status === "open" ? "statusResolved" : "statusOpen",
        run: () => toggleStatus(openThread),
      });
      items.push({
        id: "a:link",
        section: "action",
        title: t("palette.copyThreadLink"),
        detail: "C",
        icon: "link",
        run: () => copyLink(openThread.root),
      });
    }
    if (open) {
      items.push({
        id: "a:view",
        section: "action",
        title: t(view === "threads" ? "palette.showTimeline" : "palette.showThreads"),
        icon: view === "threads" ? "timeline" : "threads",
        run: () => setView(view === "threads" ? "timeline" : "threads"),
      });
    }
    if (online && everyone.length > 0)
      items.push({
        id: "a:channel",
        section: "action",
        title: t("rail.addChannel"),
        icon: "compose",
        run: () => setAddChannel(document.querySelector(".hc-list-header .hc-icon-button") ?? document.body),
      });
    for (const thread of threads)
      items.push({
        id: `t:${thread.id}`,
        section: "thread",
        title: thread.title,
        keywords: [people.get(thread.owner)?.name ?? "", place],
        detail: `${place} · ${t(thread.status === "open" ? "status.open" : "status.resolved")}`,
        icon: thread.status === "open" ? "statusOpen" : "statusResolved",
        run: () => {
          setView("threads");
          openThreadId(thread.id);
        },
      });
    for (const c of [...snap.conversations.values()].sort((a, b) => b.updatedAt - a.updatedAt)) {
      const isChannel = channels.has(c.id);
      items.push({
        id: `c:${c.id}`,
        section: "conversation",
        title: conversationName(c, me),
        keywords: c.participants.map((p) => p.name),
        detail: c.unread > 0 ? format("unread.messages", String(c.unread)) : undefined,
        icon: isChannel ? <span className="hc-palette-hash">#</span> : <Avatar participant={c.participants.find((p) => p.id !== me)} size={18} />,
        run: () => select(c.id),
      });
    }
    return items;
    // oxlint-disable-next-line react-hooks/exhaustive-deps -- rebuilt when the palette opens.
  }, [palette]);

  const withThread = openThread !== undefined;
  return (
    <div className={`hc-page${withThread ? " with-thread" : ""}`}>
      <ConversationList
        conversations={snap.conversations}
        me={me}
        selected={snap.selected}
        busy={snap.busy}
        threadIndex={snap.threadIndex}
        threadEdits={snap.threadEdits}
        people={people}
        strings={strings}
        onSelect={select}
        onOpenPalette={() => setPalette(true)}
        onAddChannel={online && everyone.length > 0 ? (anchor) => setAddChannel(anchor) : undefined}
      />
      <section className="hc-conv" aria-label={place}>
        <header className="hc-conv-header">
          <div className="hc-conv-heading">
            <h1 className="hc-conv-title">
              {channel && (
                <span className="hc-hash" aria-hidden="true">
                  #
                </span>
              )}
              {name}
            </h1>
            <p className={`hc-conv-sub${state ? ` ${state.kind}` : ""}`}>
              {state && state.kind !== "idle" && <span className={`hc-state-dot inline ${state.kind}`} aria-hidden="true" />}
              {!online ? t(snap.connection === "connecting" ? "connection.connecting" : "connection.offline") : subtitle}
            </p>
          </div>
          {open && (
            <div className="hc-views" role="tablist" aria-label={t("view.label")}>
              {(["threads", "timeline"] as const).map((value) => (
                <button
                  key={value}
                  type="button"
                  role="tab"
                  aria-selected={view === value}
                  className={`hc-view${view === value ? " on" : ""}`}
                  onClick={() => setView(value)}
                >
                  <HomeIcon name={value} size={15} />
                  <span>{t(`view.${value}`)}</span>
                </button>
              ))}
            </div>
          )}
          {open && channel && (
            <span className="hc-members" title={format("header.members", String(open.participants.length))}>
              <span className="hc-members-faces" aria-hidden="true">
                {open.participants.slice(0, 4).map((p) => (
                  <Avatar key={p.id} participant={p} size={22} />
                ))}
              </span>
            </span>
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
        {view === "threads" ? (
          <ThreadsList
            threads={threads}
            people={people}
            me={me}
            filter={filter}
            onFilter={(value) => {
              setFilter(value);
              setFocus(undefined);
            }}
            focused={focus}
            open={snap.thread}
            loose={looseCount}
            hasOlder={snap.hasOlder}
            loadingOlder={snap.loadingOlder}
            onLoadOlder={() => void store.loadOlder()}
            onOpen={openThreadId}
            onShowTimeline={() => setView("timeline")}
            showResolved={showResolved}
            onShowResolved={setShowResolved}
            strings={strings}
          />
        ) : (
          <Timeline
            conversation={snap.selected}
            rows={rows}
            people={people}
            me={me}
            strings={strings}
            loadingOlder={snap.loadingOlder}
            onLoadOlder={() => void store.loadOlder()}
            onOpenThread={openThreadId}
            onReact={(message, value) => void store.react(message, value)}
            onCopyLink={copyLink}
            highlight={snap.highlight}
            focused={snap.thread ? undefined : focus}
            pending={pendingIds}
            onRetry={(id) => store.retrySend(id)}
            onDiscard={(id) => store.discardSend(id)}
            {...editActions("main")}
          />
        )}
        <div className="hc-typing" aria-live="polite">
          {typingNames.length === 1
            ? format("typing.one", typingNames[0]!)
            : typingNames.length > 1
              ? t("typing.many")
              : ""}
        </div>
        {open && (
          <div className="hc-conv-compose">
            <Composer
              key={`${open.id}-${view}`}
              strings={strings}
              placeholder={format(view === "threads" ? "composer.newThread" : "composer.placeholder", place)}
              label={format(view === "threads" ? "composer.newThread" : "composer.placeholder", name)}
              disabled={!online}
              people={mentionable}
              quiet
              onEditLast={() => {
                const last = lastEditable(snap.messages, me);
                if (last) {
                  setView("timeline");
                  setEditing({ id: last.id, surface: "main" });
                }
              }}
              onSend={(text) => store.send(text, undefined, undefined, view === "threads")}
            />
          </div>
        )}
      </section>
      {openThread && (
        <WorkThreadView
          key={openThread.id}
          thread={openThread}
          place={place}
          messages={threadSource}
          pendingIds={pendingIds}
          hasMore={snap.threadView?.hasMore}
          loadingMore={snap.threadView?.loading}
          onLoadMore={() => store.loadMoreReplies()}
          people={people}
          members={members}
          me={me}
          strings={strings}
          canSend={online}
          focused={focus}
          replyTo={replyTo}
          onReplyTo={setReplyTo}
          focusComposer={composerFocus}
          onClose={() => openThreadId(undefined)}
          onStatus={(status) => {
            store.setThreadStatus(openThread.id, status);
            flash(t(status === "resolved" ? "toast.resolved" : "toast.reopened"));
          }}
          onOwner={(owner) => store.setThreadOwner(openThread.id, owner)}
          onSend={(text, parent) => store.send(text, openThread.id, parent)}
          onCopyLink={copyLink}
          onRetry={(id) => store.retrySend(id)}
          onDiscard={(id) => store.discardSend(id)}
          highlight={snap.highlight}
          onReact={(message, value) => void store.react(message, value)}
          {...editActions("thread")}
        />
      )}
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
      {toast && (
        <output className="hc-toast" aria-live="polite">
          {toast}
        </output>
      )}
    </div>
  );
}
