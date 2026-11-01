// The Channels view: the one chronological list on the start side; the open conversation (header,
// timeline, composer) on the other, with the thread sheet over the timeline. A view over the Home
// owners (HomeChannelsStore); no business rules live here. View state only: the palette, the
// create popover, the inline editor, the keyboard's current message and a short notice.
import { useEffect, useMemo, useRef, useState, useSyncExternalStore } from "react";
import type { Strings } from "../shared/i18n";
import { useLasting } from "../../ui/lasting";
import { AttachmentContext } from "./AttachmentViews";
import { AvatarContext } from "./avatars";
import { Avatar, ChannelMark, PicturesContext } from "./Avatar";
import { Composer } from "./Composer";
import { GoalStrip } from "./GoalStrip";
import { useHostSelection, type HomeSelection } from "./hostSelection";
import { useHostMove } from "./hostMove";
import { ConversationList, useStamp } from "./ConversationList";
import { HomeIcon } from "./icons";
import {
  activityAt,
  channelIds,
  chiefState,
  chronological,
  conversationName,
  isUnread,
  lastEditable,
  listOrder,
  mergeMessages,
  messageLink,
  others,
  pendingMessages,
  threadSummaries,
  threadOf,
  timelineRows,
  withChiefNames,
  withDraft,
} from "./model";
import { Palette, type PaletteItem } from "./Palette";
import { backToList, conversationHash, setHash, useHashPane, useNarrow, type Pane } from "./panes";
import { RunsContext, type RunsContextValue } from "./RunCard";
import { useRunEntry } from "./runs";
import { ChiefRoutePage, RouteSheets } from "./RouteSheets";
import { LiveTyping } from "./LiveTyping";
import { chiefPresence } from "../../agent-session/acpmux/multiplayer/chiefAdapter";
import { PresenceStack } from "../../agent-session/acpmux/multiplayer/Faces";
import { RunSheet } from "./RunSheet";
import type { HomeChannelsStore } from "./store";
import { lastLiveReplies, threadObject, type ThreadObject } from "./threads";
import { ThreadSheet } from "./ThreadSheet";
import { Timeline } from "./Timeline";
import type { HomeConversation, HomeMessage, HomeParticipant, HomeRun } from "./types";
import { useHomeKeys } from "./useHomeKeys";
import { useWebSwapHold } from "../shared/useWebSwapHold";

const NOTICE_MS = 1600;

export function HomeChannelsPage({
  store,
  strings,
  pane: fixedPane,
}: {
  store: HomeChannelsStore;
  strings: Strings;
  /** The pane a narrow page shows, instead of the hash's (the gallery, whose hash is its own). */
  pane?: Pane;
}) {
  const snap = useSyncExternalStore(store.subscribe, store.getSnapshot);
  // WEB-SWAP: a web update's reload waits while a message lives only in this page: one on its way
  // to the owner, or a failed one with Retry (pages/shared/webSwap.ts).
  useWebSwapHold(
    snap.pending.some((entry) => !entry.failed) ? "home.sending" : snap.pending.length ? "home.send-failed" : null,
  );
  // Below NARROW_PAGE of its own width the page shows one pane (panes.ts), the one the hash names.
  const shell = useRef<HTMLDivElement>(null);
  const measured = useNarrow(shell);
  const narrow = measured === true;
  const hashPane = useHashPane();
  const pane = fixedPane ?? hashPane;
  const sheetState = useSyncExternalStore(store.sheets.subscribe, store.sheets.getSnapshot);
  const caps = sheetState.capabilities;
  // New Chief and Edit Chief are a page on the right side, in place of the conversation (u2586).
  const chiefPage = sheetState.route?.kind === "newChief" || sheetState.route?.kind === "editChief";
  const [palette, setPalette] = useState(false);
  const [editing, setEditing] = useState<{ id: string; surface: "main" | "thread" } | undefined>();
  const [focused, setFocused] = useState<string | undefined>();
  const [notice, setNotice] = useState<string | undefined>();
  /** The run the run sheet shows (an agent turn's whole trajectory). */
  const [openRun, setOpenRun] = useState<{ conversation: string; author: string; id: string } | undefined>();
  // WEB-SWAP: an open thread, run sheet, palette or edit lives only in this page's state, so a reload
  // would close it: the update waits until it closes (pages/shared/webSwap.ts).
  useWebSwapHold(snap.thread || openRun || palette || editing || sheetState.route ? "home.sheet" : null);
  const runs = useMemo<RunsContextValue>(
    () => ({
      book: store.runs,
      strings,
      onOpen: (run: HomeRun) => setOpenRun({ conversation: run.conversation, author: run.author, id: run.id }),
      onLoad: (run: HomeRun) => void store.loadRunSteps(run),
      live: store.live,
    }),
    [store, strings],
  );
  const runSheet = useRunEntry(store.runs, (book) =>
    openRun ? book.get(openRun.conversation, openRun.author, openRun.id) : undefined,
  );
  const noticeTimer = useRef<number | undefined>(undefined);
  /** The status each root was last asked to take, until the owner's event shows it (two quick
   * presses of E resolve, then reopen). */
  const asked = useRef(new Map<string, "open" | "resolved">());
  const { t, format } = strings;
  const stamp = useStamp(strings.language);
  const column = useRef<HTMLDivElement | null>(null);
  const me = snap.me?.id;
  const channels = useMemo(() => channelIds(snap.conversations.values(), me), [snap.conversations, me]);
  // A Chief's direct message shows the Chief's current name (its record), not the name its
  // conversation was made with ("Chief" for every brain's own DM).
  const conversations = useMemo(
    () => withChiefNames(snap.conversations, channels, me, sheetState.chiefs),
    [snap.conversations, channels, me, sheetState.chiefs],
  );
  const open = snap.selected ? conversations.get(snap.selected) : undefined;
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
    for (const conversation of conversations.values()) for (const p of conversation.participants) map.set(p.id, p);
    if (snap.me) map.set(snap.me.id, snap.me);
    return map;
  }, [conversations, snap.me]);
  const runsWithPeople = useMemo<RunsContextValue>(
    () => ({ ...runs, people, draftTurn: snap.draft?.turn }),
    [runs, people, snap.draft?.turn],
  );
  const mentionable = useMemo(() => others(open, me), [open, me]);
  const online = snap.connection === "online";
  // The header says the page is offline or connecting only once that has lasted past the grace
  // (ui/lasting.ts): a daemon restart or a dropped link that comes back shows nothing.
  const offlineLasting = useLasting(!online);
  const name = open ? conversationName(open, me) : "";
  const channel = open ? channels.has(open.id) : false;
  const place = channel ? `#${name}` : name;
  const state = open && !channel ? chiefState(open, me, snap.activity.get(open.id)) : undefined;
  // Thread objects (the owner's fields; threads.ts): the newest live reply of each root in the
  // window and in the open thread's pages.
  const newestReply = useMemo(() => lastLiveReplies([...shown, ...threadSource], threadOf), [shown, threadSource]);
  const threadFor = (root: HomeMessage): ThreadObject =>
    threadObject(root, snap.threadStats.get(root.id), newestReply.get(root.id));
  // Threads of the open conversation (loaded roots), newest first.
  const threads = useMemo(() => {
    const summaries = threadSummaries(shown, snap.unseen, me, snap.threadsSeen, snap.threadStats);
    return shown
      .filter((m) => summaries.has(m.id))
      .map((m) => ({
        object: threadObject(m, snap.threadStats.get(m.id), newestReply.get(m.id)),
        summary: summaries.get(m.id)!,
        root: m,
      }))
      .reverse();
  }, [shown, snap.unseen, me, snap.threadsSeen, snap.threadStats, newestReply]);
  const openThreads = threads.filter((entry) => entry.object.status === "open").length;
  const sheetRoot = snap.thread ? threadSource.find((m) => m.id === snap.thread) : undefined;
  const sheetThread = sheetRoot ? threadFor(sheetRoot) : undefined;
  // What j/k walk: the timeline's messages and thread rows (not my pending sends).
  const walk = useMemo(
    () =>
      rows.flatMap((row) => (row.kind === "message" && !row.message.id.startsWith("pending:") ? [row.message] : [])),
    [rows],
  );
  // The people here and typing, as the agent chat shows them (multiplayer/chiefAdapter.ts): only
  // this conversation's members, so a stray id never draws someone from another conversation.
  const presence = useMemo(
    () => chiefPresence(new Map(open?.participants.map((p) => [p.id, p])), me ?? "", snap.typing, snap.viewing),
    [open?.participants, me, snap.typing, snap.viewing],
  );
  const typingNames = snap.typing
    .filter((id) => id !== me && id !== snap.draft?.participant)
    .map((id) => people.get(id)?.name ?? id);

  const say = (text: string) => {
    setNotice(text);
    window.clearTimeout(noticeTimer.current);
    noticeTimer.current = window.setTimeout(() => setNotice(undefined), NOTICE_MS);
  };
  const copyLink = (message?: HomeMessage, conversation = snap.selected) => {
    if (!conversation || !navigator.clipboard) return;
    // The notice only when the copy happened.
    navigator.clipboard.writeText(messageLink(conversation, message?.id)).then(
      () => say(t("notice.linkCopied")),
      () => undefined,
    );
  };
  // A list row's menu (right-click, Shift-F10): my pin, my unread mark, the conversation's link.
  const rowActions = {
    canPin: snap.inboxState,
    onPin: (id: string, pinned: boolean) => void store.setPinned(id, pinned),
    onMarkUnread: (id: string) => void store.setMarkedUnread(id, true),
    onMarkRead: (id: string) => store.markConversationRead(id),
    onCopyLink: (id: string) => copyLink(undefined, id),
  };
  /** Opens a conversation: the hash names it (the narrow page shows its pane; a reload and the
   * host see the same), and the store opens it at once. `replace`: a keyboard move through the
   * list keeps one history entry. */
  const select = (id: string, replace = false) => {
    setEditing(undefined);
    setFocused(undefined);
    void store.select(id);
    // The hash records it (the narrow page's pane, a reload, the host); followHash sees it is open.
    if (store.routed) setHash(conversationHash(id), replace);
  };
  /** Back to the list (the narrow page's one pane). */
  const back = () => {
    if (store.routed) backToList();
  };
  const canGoBack = narrow && pane === "conversation" && store.routed;
  const listShown = narrow && pane === "list";
  // A conversation behind the narrow page's list is not read; the keyboard follows the pane.
  const lastPane = useRef<boolean | undefined>(undefined);
  useEffect(() => {
    if (measured === undefined) return;
    store.setShown(!listShown);
    // Only a pane change moves focus (Back, a row), never the first measured render (the page may
    // load in the background of the Home dock).
    const changed = lastPane.current !== undefined && lastPane.current !== listShown;
    lastPane.current = listShown;
    if (!narrow || !changed) return;
    const target = listShown
      ? (document.querySelector<HTMLElement>("[data-list-row][aria-current]") ??
        document.querySelector<HTMLElement>("[data-list-row]"))
      : document.querySelector<HTMLElement>(".lg-back");
    target?.focus({ preventScroll: true });
  }, [store, measured, narrow, listShown]);
  const openThread = (root: string | undefined) => {
    setEditing(undefined);
    void store.openThread(root);
  };
  const focusComposer = (scope: string) =>
    window.requestAnimationFrame(() =>
      document.querySelector<HTMLElement>(`${scope} [contenteditable="true"], ${scope} textarea`)?.focus(),
    );
  /** Resolves or reopens a thread on its owner (`thread.update`); the root's event shows it. */
  const toggleStatus = (rootId: string) => {
    const root = threadSource.find((m) => m.id === rootId) ?? shown.find((m) => m.id === rootId);
    if (!root) return;
    const seen = threadFor(root).status;
    const pendingAsk = asked.current.get(rootId);
    const current = pendingAsk && pendingAsk !== seen ? pendingAsk : seen;
    const status = current === "resolved" ? "open" : "resolved";
    asked.current.set(rootId, status);
    void store.updateThread(root, { status }).then((done) => {
      if (asked.current.get(rootId) === status) asked.current.delete(rootId);
      if (done) say(t(status === "resolved" ? "notice.resolved" : "notice.reopened"));
    });
  };
  const setOwner = (rootId: string, owner: string) => {
    const root = threadSource.find((m) => m.id === rootId) ?? shown.find((m) => m.id === rootId);
    if (root) void store.updateThread(root, { owner });
  };
  const focusedMessage = focused ? walk.find((m) => m.id === focused) : undefined;
  // What the host's `home.currentSelection` answers (the dock's view switch): the open
  // conversation and the message the person is on; null on the narrow list pane.
  const selectionMessage = focusedMessage?.id ?? snap.highlight ?? snap.thread;
  const selection = useMemo<HomeSelection | null>(
    () =>
      // Before the first measure the page does not know yet whether only the list shows.
      measured === undefined || listShown || !snap.selected
        ? null
        : { conversation: snap.selected, ...(selectionMessage ? { message: selectionMessage } : {}) },
    [measured, listShown, snap.selected, selectionMessage],
  );
  useHostSelection(store.host, selection);
  const moveList = (delta: 1 | -1, unreadOnly: boolean): boolean => {
    // The order the list shows: my pins first, then newest activity.
    const { pinned, rest } = listOrder(snap.conversations.values());
    const order = [...pinned, ...rest];
    const n = order.length;
    const start = order.findIndex((c) => c.id === snap.selected);
    const base = start < 0 ? (delta > 0 ? -1 : n) : start;
    for (let step = 1; step <= n; step += 1) {
      const next = order[(((base + delta * step) % n) + n) % n];
      if (next && (!unreadOnly || isUnread(next))) {
        select(next.id, true);
        return true;
      }
    }
    return false;
  };
  // The host's Cmd-Shift-[ / ] while the docked Home shows Channels (hostMove.ts).
  useHostMove(store.host, (delta) => moveList(delta, false));
  useHomeKeys({
    openPalette: () => setPalette(true),
    move: moveList,
    escape: (inField) => {
      // The narrow list pane hides the conversation: its edit, run, thread and focus are not
      // what Escape closes there.
      if (sheetState.route) store.sheets.close();
      else if (palette) setPalette(false);
      else if (listShown) return false;
      else if (editing) setEditing(undefined);
      else if (openRun) setOpenRun(undefined);
      else if (snap.thread) openThread(undefined);
      else if (focused) setFocused(undefined);
      else if (canGoBack && !inField) back();
      else return false;
      return true;
    },
    back: (inField) => {
      if (!canGoBack || inField) return false;
      back();
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
      const target =
        snap.thread ??
        (focusedMessage && threads.some((x) => x.root.id === focusedMessage.id) ? focusedMessage.id : undefined);
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

  /** The Chief record of a direct message with a Chief (the page can edit it). */
  const chiefOf = (conversation: HomeConversation) => {
    if (channels.has(conversation.id)) return undefined;
    const others = conversation.participants.filter((p) => p.id !== me);
    return others.length === 1 && others[0]!.chief ? sheetState.chiefs.get(others[0]!.id) : undefined;
  };
  const openChief = open ? chiefOf(open) : undefined;
  const paletteItems = useMemo<PaletteItem[]>(() => {
    const items: PaletteItem[] = [];
    for (const c of chronological(conversations.values())) {
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
          entry.summary.count === 1
            ? t("thread.replies.one")
            : format("thread.replies.many", String(entry.summary.count))
        }`,
        mark: <span className={`lg-status ${entry.object.status}`} />,
        run: () => openThread(entry.root.id),
      });
    }
    if (online && caps.start)
      items.push({
        id: "a:new-message",
        group: "actions",
        title: t("action.newMessage"),
        keywords: [t("rail.addChannel")],
        mark: <HomeIcon name="compose" size={16} />,
        run: () => store.sheets.open({ kind: "newMessage" }),
      });
    if (online && caps.chiefs)
      items.push({
        id: "a:new-chief",
        group: "actions",
        title: t("action.newChief"),
        mark: <HomeIcon name="plus" size={16} />,
        run: () => store.sheets.open({ kind: "newChief" }),
      });
    const current = snap.selected ? conversations.get(snap.selected) : undefined;
    if (online && caps.invite && current?.owner === "local")
      items.push({
        id: "a:invite",
        group: "actions",
        title: t("action.invite"),
        mark: <HomeIcon name="personAdd" size={16} />,
        run: () => store.sheets.open({ kind: "invite", conversation: current.id }),
      });
    const chiefHere = current ? chiefOf(current) : undefined;
    if (online && chiefHere)
      items.push({
        id: "a:edit-chief",
        group: "actions",
        title: t("action.editChief"),
        mark: <HomeIcon name="edit" size={16} />,
        run: () => store.sheets.open({ kind: "editChief", chief: chiefHere.id }),
      });
    if (online && chiefHere && !chiefHere.isDefault && sheetState.chiefGrants)
      items.push({
        id: "a:archive-chief",
        group: "actions",
        title: t("action.archiveChief"),
        mark: <HomeIcon name="close" size={16} />,
        run: () => store.sheets.open({ kind: "archiveChief", chief: chiefHere.id }),
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
    if (snap.thread && me && sheetThread?.owner !== me)
      items.push({
        id: "a:assign-me",
        group: "actions",
        title: t("thread.assignMe"),
        mark: <HomeIcon name="check" size={16} />,
        run: () => snap.thread && setOwner(snap.thread, me),
      });
    const openRow = snap.selected ? conversations.get(snap.selected) : undefined;
    if (openRow && snap.inboxState)
      items.push({
        id: "a:pin",
        group: "actions",
        title: t(openRow.pinned ? "action.unpinConversation" : "action.pinConversation"),
        keywords: ["pin"],
        mark: <HomeIcon name="pin" size={16} />,
        run: () => void store.setPinned(openRow.id, !openRow.pinned),
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
  }, [
    conversations,
    channels,
    me,
    threads,
    online,
    snap.thread,
    snap.selected,
    snap.inboxState,
    sheetThread?.status,
    sheetThread?.owner,
    stamp,
    caps,
    sheetState.chiefs,
    sheetState.chiefGrants,
  ]);

  const empty = snap.conversations.size === 0 && !snap.loading;
  // Files go to the open conversation when its owner takes them through this host.
  const takesFiles =
    open && snap.fileSupport && (open.owner === "cloud" ? snap.fileSupport.cloud : snap.fileSupport.local);
  const openId = open?.id;
  const uploads = useMemo(
    () =>
      store.attachments && takesFiles && openId ? { service: store.attachments, conversation: openId } : undefined,
    [store.attachments, takesFiles, openId],
  );
  return (
    <AttachmentContext.Provider value={store.attachments}>
      <AvatarContext.Provider value={store.avatars}>
        <PicturesContext.Provider value={sheetState.pictures}>
          <div className="lg-shell" ref={shell}>
            <div className="lg-page" data-pane={pane}>
              <ConversationList
                conversations={conversations}
                channels={channels}
                people={people}
                activity={snap.activity}
                me={me}
                selected={snap.selected}
                strings={strings}
                onSelect={select}
                onOpenPalette={() => setPalette(true)}
                onCompose={online && caps.start ? () => store.sheets.open({ kind: "newMessage" }) : undefined}
                onNewChief={online && caps.chiefs ? () => store.sheets.open({ kind: "newChief" }) : undefined}
                actions={rowActions}
                chiefs={sheetState.chiefs}
              />
              <section
                className={`lg-main${snap.thread && !chiefPage ? " with-sheet" : ""}`}
                aria-label={chiefPage ? undefined : place || t("page.title")}
              >
                {chiefPage ? (
                  <ChiefRoutePage sheets={store.sheets} state={sheetState} strings={strings} />
                ) : snap.loading ? null : empty || !open ? (
                  <EmptyState
                    strings={strings}
                    noConversations={empty}
                    canCreate={online && caps.start}
                    onCreate={() => store.sheets.open({ kind: "newMessage" })}
                    onPalette={() => setPalette(true)}
                  />
                ) : (
                  <>
                    <header className="lg-header">
                      <button
                        type="button"
                        className="hc-icon-button lg-back"
                        aria-label={t("action.back")}
                        aria-keyshortcuts="Meta+["
                        onClick={back}
                      >
                        <HomeIcon name="chevronLeft" size={16} />
                      </button>
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
                            {openThreads === 1
                              ? t("header.openThread.one")
                              : format("header.openThreads", String(openThreads))}
                          </span>
                        )}
                      </p>
                      <span className="lg-spacer" />
                      {offlineLasting && (
                        <output className="lg-connection">
                          {t(snap.connection === "connecting" ? "connection.connecting" : "connection.offline")}
                        </output>
                      )}
                      {notice && <output className="lg-notice">{notice}</output>}
                      {/* Who else has the chat open: the agent chat's faces (multiplayer/Faces.tsx). */}
                      <PresenceStack viewing={presence.viewing} />
                      {channel && (
                        <span className="lg-faces" aria-hidden="true">
                          {open.participants.slice(0, 4).map((p) => (
                            <Avatar key={p.id} participant={p} size={20} />
                          ))}
                        </span>
                      )}
                      {online && caps.invite && open.owner === "local" && (
                        <button
                          type="button"
                          className="hc-icon-button"
                          aria-label={t("action.invite")}
                          title={t("action.invite")}
                          onClick={() => store.sheets.open({ kind: "invite", conversation: open.id })}
                        >
                          <HomeIcon name="personAdd" size={16} />
                        </button>
                      )}
                      {online && openChief && (
                        <button
                          type="button"
                          className="hc-icon-button"
                          aria-label={t("action.editChief")}
                          title={t("action.editChief")}
                          onClick={() => store.sheets.open({ kind: "editChief", chief: openChief.id })}
                        >
                          <HomeIcon name="edit" size={16} />
                        </button>
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
                    <RunsContext.Provider value={runsWithPeople}>
                      <div className="lg-stage" ref={column} data-drop-zone>
                        <GoalStrip book={store.runs} conversation={open.id} strings={strings} onOpen={runs.onOpen} />
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
                          threadFor={threadFor}
                          openThread={snap.thread}
                          focused={focused}
                          pendingState={pendingState}
                          onRetry={(key) => store.retry(key)}
                          onDiscard={(key) => store.discard(key)}
                          stamp={stamp}
                          empty={t("timeline.empty")}
                          {...editActions("main")}
                        />
                        <LiveTyping
                          conversation={open.id}
                          live={store.live}
                          runs={store.runs}
                          people={people}
                          typing={typingNames}
                          draftTurn={snap.draft?.turn}
                          strings={strings}
                          onOpen={runs.onOpen}
                        />
                        <div className="lg-main-compose">
                          <Composer
                            key={open.id}
                            strings={strings}
                            placeholder={format("composer.placeholder", place)}
                            label={format("composer.placeholder", name)}
                            disabled={!online}
                            people={mentionable}
                            onEditLast={() => {
                              const last = lastEditable(
                                snap.messages,
                                me,
                                new Set(threads.map((entry) => entry.root.id)),
                              );
                              if (last) setEditing({ id: last.id, surface: "main" });
                            }}
                            attachments={uploads}
                            dropZone={column}
                            onSend={(text, files) => store.send(text, undefined, undefined, files)}
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
                            owners={open.participants}
                            onSetOwner={(owner) => snap.thread && setOwner(snap.thread, owner)}
                            onRename={(title) =>
                              sheetRoot ? store.updateThread(sheetRoot, { title }) : Promise.resolve(false)
                            }
                            onSend={(text, parent, files) => store.send(text, snap.thread, parent, files)}
                            attachments={uploads}
                            onCopyLink={(message) => copyLink(message)}
                            onReact={(message, value) => void store.react(message, value)}
                            pendingState={pendingState}
                            onRetry={(key) => store.retry(key)}
                            onDiscard={(key) => store.discard(key)}
                            {...editActions("thread")}
                          />
                        )}
                        {runSheet && runSheet.run.conversation === snap.selected && (
                          <RunSheet
                            key={`${runSheet.run.author}:${runSheet.run.id}`}
                            entry={runSheet}
                            people={people}
                            strings={strings}
                            place={place}
                            asked={askedLine(runSheet.run.answers[0], threadSource)}
                            onClose={() => setOpenRun(undefined)}
                            onLoad={runs.onLoad}
                          />
                        )}
                      </div>
                    </RunsContext.Provider>
                  </>
                )}
              </section>
              <RouteSheets
                sheets={store.sheets}
                state={sheetState}
                strings={strings}
                conversations={conversations}
                me={me}
              />
              {palette && <Palette items={paletteItems} strings={strings} onClose={() => setPalette(false)} />}
            </div>
          </div>
        </PicturesContext.Provider>
      </AvatarContext.Provider>
    </AttachmentContext.Provider>
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
  onCreate(): void;
  onPalette(): void;
}) {
  const { t } = strings;
  return (
    <div className="lg-empty">
      <h1 className="lg-empty-title">{t(noConversations ? "empty.title" : "empty.pick.title")}</h1>
      <p className="lg-empty-body">{t(noConversations ? "empty.body" : "empty.pick.body")}</p>
      <div className="lg-empty-actions">
        {noConversations && canCreate && (
          <button type="button" className="lg-button primary" onClick={onCreate}>
            {t("action.newMessage")}
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

/** The first line of the message a run works on (the run sheet's title when the run has none). */
function askedLine(id: string | undefined, messages: readonly HomeMessage[]): string | undefined {
  const message = id ? messages.find((entry) => entry.id === id) : undefined;
  const text = message?.parts.find((part) => part.type === "text");
  const line = text && text.type === "text" ? text.text.split("\n")[0]!.trim() : "";
  return line ? (line.length > 120 ? `${line.slice(0, 119)}…` : line) : undefined;
}
