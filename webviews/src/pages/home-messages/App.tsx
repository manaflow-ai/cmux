// The Messages page's shell: the conversation list in a resizable column on the left and the detail
// slot on the right (the transcript and composer, the sheets and the in-chat cards plug in there),
// with the chat's compose button over the slot's top-left, as the native Home lays them out
// (`HomeSidebarSplitView`, `HomeChatColumnView`). It reads the Channels data layer's store and keeps
// only view state of its own: the search, the Unread filter and the column's width.
//
// - The column is 320 pt to start, between 76 pt (avatars only) and the smaller of half the page and
//   what leaves the transcript 280 pt. A drag of the divider sets it, kept by the app for this
//   window (HomeSidebarWidth, saved only by a drag, kept while a narrow page squeezes it); a
//   double-click puts it back. The divider lights in the accent while hovered or dragged.
// - The app adds each row's Chief tag, the Cloud note, the teammates with no DM yet and the
//   header's sizes (the `list` stream); choosing a teammate starts the DM and opens it.
// - The list header's band, but its controls, moves the window (the host's drag strip).
// - A narrow page that would squeeze a list of one conversation to avatars folds the column away.
// - The window's traffic lights are the host's value: the list's header and compose keep clear.
import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  useSyncExternalStore,
  type CSSProperties,
  type PointerEvent as ReactPointerEvent,
} from "react";
import { ContextMenu, type ContextMenuItem } from "../../ui/ContextMenu";
import { AvatarContext } from "../home-channels/avatars";
import { HomeIcon } from "../home-channels/icons";
import type { HomeChannelsStore } from "../home-channels/store";
import type { Strings } from "../shared/i18n";
import type { PageClient } from "../shared/pageClient";
import { documentDom, pageDebug, useDebugCommands, withFixture } from "./debugCommands";
import { ConversationList, DRAFT_ROW } from "./list/ConversationList";
import { clampWidth, COMPACT_BELOW, HEADER, WIDTH } from "./list/layout";
import { holdsOneConversation, listModel, visibleConversations } from "./list/model";
import { NO_LIST_FACTS } from "./host";
import { MessagesNav } from "./nav";
import { closeNewMessage, followPageFocus, followTyping, reportedConversation, usePageCommands } from "./pageCommands";
import { useSeeThrough } from "./seeThrough";
import { MessagesSheetOps } from "./sheets/actions";
import type {
  HiddenConversations,
  HostMenuItem,
  ListFacts,
  MessagesChrome,
  MessagesDetail,
  MessagesHost,
  Rect,
} from "./types";

export interface MessagesAppProps {
  store: HomeChannelsStore;
  strings: Strings;
  /** The app host (null in a browser). */
  host: PageClient | null;
  messages: MessagesHost;
  /** What the slot right of the list draws (the transcript, the sheets, the cards). */
  detail?: MessagesDetail;
  /** New Message (absent: the page's own New Message opens). */
  onCompose?(): void;
  /** The page's view state (absent: the page makes its own). */
  nav?: MessagesNav;
  /** Where the column's width is kept without a host (a browser; null: not kept, the gallery). In
   * the app the host keeps it per window (`width.load|save`). */
  widthStorage?: Storage | null;
  /** The one conversation a conversation tab or the Chief panel shows (single.ts): no list column,
   * no compose button, and the page keeps that conversation open. */
  single?: string;
}

const WIDTH_KEY = "cmux.home.sidebarWidth";
const NONE_HIDDEN: HiddenConversations = new Map();
const COMPOSE_INSET = 12;

export function MessagesApp({
  store,
  strings,
  host,
  messages,
  detail,
  onCompose,
  widthStorage,
  single,
  ...props
}: MessagesAppProps) {
  const snapshot = useSyncExternalStore(store.subscribe, store.getSnapshot);
  const [ownNav] = useState(() => new MessagesNav());
  const nav = props.nav ?? ownNav;
  const view = useSyncExternalStore(nav.subscribe, nav.getSnapshot);
  const composing = view.compose?.shown === true;
  const { t, format, language } = strings;
  const [chrome, setChrome] = useState<MessagesChrome>({ windowControls: null });
  useEffect(() => messages.subscribeChrome(setChrome), [messages]);
  // The floating Chief's see-through styles: no page background, the header's height to the host.
  useSeeThrough(host);
  // Deleted from the list (Delete Conversation…): off it until a newer message.
  const [hidden, setHidden] = useState<HiddenConversations>(NONE_HIDDEN);
  useEffect(() => messages.subscribeHidden(setHidden), [messages]);
  // DEBUG captures' fixture rows and look (debugCommands.ts; empty unless the app's DEBUG verbs ask).
  const debug = useSyncExternalStore(pageDebug.subscribe, pageDebug.getSnapshot);
  // The app's facts about the list (tags, the Cloud note, teammates, the header's sizes).
  const [facts, setFacts] = useState<ListFacts>(NO_LIST_FACTS);
  useEffect(() => messages.subscribeList(setFacts), [messages]);
  // A DEBUG fixture's `team` is the list's teammate rows too, as the native list drew them.
  const debugTeam = useMemo(
    () =>
      debug.contacts
        ?.filter((contact) => contact.source === "team")
        .map((contact) => ({ id: contact.id, name: contact.name })),
    [debug.contacts],
  );
  const listed = useMemo(
    () => withFixture(visibleConversations(snapshot.conversations, hidden), debug),
    [snapshot.conversations, hidden, debug],
  );
  // The page getting the keyboard gives it to the message box (or New Message's To:).
  useEffect(() => followPageFocus(window, document, nav), [nav]);
  // A letter typed while the page or the list has the keyboard goes to the message box (or To:).
  useEffect(() => followTyping(window, document, nav), [nav]);
  const [query, setQuery] = useState("");
  const [unreadOnly, setUnreadOnly] = useState(false);
  const [openedAt, setOpenedAt] = useState<number | undefined>();
  const [now, setNow] = useState(() => Date.now());
  // "Today" and "Yesterday" move at midnight; one timer to the next minute boundary is enough.
  useEffect(() => {
    const timer = setTimeout(() => setNow(Date.now()), 60_000 - (now % 60_000));
    return () => clearTimeout(timer);
  }, [now]);

  const me = snapshot.me?.id;
  const words = useMemo(
    () => ({
      untitled: t("home.list.untitled"),
      yesterday: t("home.sidebar.yesterday"),
      channel: t("home.list.channel"),
      mentioned: t("home.list.mentioned"),
      unread: (count: number) => format("home.list.unread", String(count)),
    }),
    [t, format],
  );
  const model = useMemo(
    () =>
      listModel(listed, {
        ...(me ? { me } : {}),
        query,
        unreadOnly,
        now,
        language,
        words,
        activity: snapshot.activity,
        badges: facts.badges,
        teammates: debugTeam ?? facts.teammates,
        people: debugTeam ?? facts.people,
      }),
    [listed, snapshot.activity, me, query, unreadOnly, now, language, words, facts, debugTeam],
  );

  // The page's width, and the column's own (kept between opens).
  const page = useRef<HTMLDivElement | null>(null);
  const [pageWidth, setPageWidth] = useState(1200);
  useEffect(() => {
    const element = page.current;
    if (!element) return;
    const observer = new ResizeObserver(() => setPageWidth(element.clientWidth || 1200));
    observer.observe(element);
    setPageWidth(element.clientWidth || 1200);
    return () => observer.disconnect();
  }, []);
  const [own, setOwn] = useState<number | undefined>(() => {
    const kept = Number(widthStorage?.getItem(WIDTH_KEY));
    return Number.isFinite(kept) && kept > 0 ? kept : undefined;
  });
  // In the app the width is this window's (the host's answer); the column waits for it, so it opens
  // at its own width rather than jumping there. `ownRef`: a drag before the answer wins.
  const [widthKnown, setWidthKnown] = useState(!host);
  const ownRef = useRef(own);
  ownRef.current = own;
  useEffect(() => {
    if (!host) return;
    let live = true;
    void messages.loadWidth().then((width) => {
      if (!live) return;
      if (width !== null && ownRef.current === undefined) setOwn(width);
      setWidthKnown(true);
    });
    return () => {
      live = false;
    };
  }, [host, messages]);
  const [dividerDragging, setDividerDragging] = useState(false);
  const wanted = debug.width ?? own ?? WIDTH.standard;
  const listWidth = clampWidth(wanted, pageWidth - WIDTH.divider);
  const folded =
    holdsOneConversation(model, { requests: view.requests.length, ...(facts.note ? { note: facts.note } : {}) }) &&
    !query &&
    !unreadOnly &&
    listWidth < COMPACT_BELOW &&
    wanted >= COMPACT_BELOW;
  const listless = folded || single !== undefined;
  const shownWidth = listless ? 0 : listWidth;

  // One conversation's page keeps it open: the store's own first pick (the newest row) never shows
  // in its place, and a reconnect that picked another goes back to it.
  useEffect(() => {
    if (single && snapshot.selected !== single && !snapshot.loading) void store.select(single);
  }, [single, snapshot.selected, snapshot.loading, store]);

  // Only the person's drag (and the double-click's reset) is kept; a narrow page's squeeze is not.
  const keep = (width: number | undefined) => {
    setOwn(width);
    if (host) messages.saveWidth(width === undefined ? null : width);
    else if (width === undefined) widthStorage?.removeItem(WIDTH_KEY);
    else widthStorage?.setItem(WIDTH_KEY, String(Math.round(width)));
  };
  const onDividerDown = (event: ReactPointerEvent<HTMLDivElement>) => {
    if (event.button !== 0) return;
    if (event.detail === 2) {
      keep(undefined);
      return;
    }
    event.preventDefault();
    const divider = event.currentTarget;
    divider.setPointerCapture(event.pointerId);
    setDividerDragging(true);
    const left = page.current?.getBoundingClientRect().left ?? 0;
    // The column follows the pointer; the width is kept once, when the button goes up.
    let last: number | undefined;
    const move = (e: PointerEvent) => {
      last = clampWidth(e.clientX - left, pageWidth - WIDTH.divider);
      setOwn(last);
    };
    const up = () => {
      setDividerDragging(false);
      if (last !== undefined) keep(last);
      divider.removeEventListener("pointermove", move);
      divider.removeEventListener("pointerup", up);
      divider.removeEventListener("pointercancel", up);
    };
    divider.addEventListener("pointermove", move);
    divider.addEventListener("pointerup", up);
    divider.addEventListener("pointercancel", up);
  };

  // The list header's band (in page points: the column starts at the page's left edge) and its
  // controls go to the host's drag strip; a folded list has none.
  const onHeaderBand = useCallback((band: Rect, controls: Rect[]) => messages.setDragBand(band, controls), [messages]);
  useEffect(() => {
    if (folded) messages.setDragBand({ x: 0, y: 0, width: 0, height: 0 }, []);
  }, [folded, messages]);
  // A teammate with no DM yet: the DM starts (HomeService.startConversation, as the native list's
  // onStartTeammate), then opens once listed and its message box takes the keyboard.
  const startTeammate = (person: string) => {
    if (!host) return;
    void host
      .call<{ outcome?: { kind?: string; conversation?: string } }>(MessagesSheetOps.start, {
        recipients: [{ contact: person }],
        text: "",
      })
      .then(async (answer) => {
        const id = answer?.outcome?.kind === "opened" ? answer.outcome.conversation : undefined;
        if (!id) return;
        if (!store.getSnapshot().conversations.has(id)) await store.reloadInbox();
        nav.leaveCompose();
        await store.select(id);
        setOpenedAt(Date.now());
        nav.requestFocus();
      })
      .catch(() => undefined);
  };

  const select = (id: string) => {
    if (id === DRAFT_ROW) return;
    nav.leaveCompose();
    void store.select(id);
  };
  const open = (id: string) => {
    nav.leaveCompose();
    void store.select(id);
    setOpenedAt(Date.now());
    nav.requestFocus();
  };
  // The host's commands (show, present, focus, move) and the shown conversation it keeps.
  // Only a conversation still listed shows: one that left the list (Leave, Delete) is not reported
  // as open, so the app moves the page on (its neighbor, else the default conversation).
  const shown = reportedConversation(snapshot.selected, listed, composing);
  const selection = useMemo(
    () => (shown ? { conversation: shown, ...(snapshot.highlight ? { message: snapshot.highlight } : {}) } : null),
    [shown, snapshot.highlight],
  );
  usePageCommands(host, { store, nav, model }, selection, { composing, ready: !snapshot.loading });
  const debugContext = {
    store,
    nav,
    model,
    ...(facts.note ? { note: facts.note } : {}),
    messages,
    strings,
    debug: pageDebug,
    setUnreadOnly,
    dom: documentDom,
    now: Date.now,
  };
  useDebugCommands(host, debugContext);
  const listSelected = debug.selected ?? snapshot.selected;
  // A reconnect's new store opens what showed last (nav.restorable).
  useEffect(() => {
    if (shown) nav.lastShown = shown;
  }, [nav, shown]);
  // A Chief conversation the owner no longer has (its Chief home made again) gave way to the live
  // Chief: the text and files typed there go with it (nav.carry, the native `replaceGone`).
  const lastChief = useRef<string | undefined>(undefined);
  useEffect(() => {
    const previous = lastChief.current;
    const next = snapshot.selected;
    // Still the same one (it may just have left the list): wait for what replaces it.
    if (next === previous) return;
    const chief = next !== undefined && snapshot.conversations.get(next)?.kind === "chief";
    lastChief.current = chief ? next : undefined;
    if (!previous || !chief || snapshot.conversations.has(previous)) return;
    nav.carry(previous, next);
  }, [nav, snapshot.selected, snapshot.conversations]);

  // Compose at the chat's top-left, after the traffic lights when they lie over it.
  const lights = chrome.windowControls;
  const slotLeft = shownWidth + (listless ? 0 : WIDTH.divider);
  let composeX = COMPOSE_INSET;
  let composeY = Math.round((HEADER.band - HEADER.side) / 2);
  if (lights && lights.x < slotLeft + composeX + HEADER.side + 8) {
    composeX = Math.max(composeX, Math.ceil(lights.x + lights.width + 8 - slotLeft));
    composeY = Math.round(lights.y + lights.height / 2 - HEADER.side / 2);
  }
  const [composeItems, setComposeItems] = useState<HostMenuItem[]>([]);
  const loadCompose = () => void messages.menu("compose").then(setComposeItems);
  const compose =
    onCompose ??
    (() => {
      nav.dismiss();
      nav.openCompose();
      nav.requestFocus();
    });
  const composeMenu: ContextMenuItem[] = composeItems.map((item) => ({
    id: item.id,
    label: item.title,
    ...(item.checked !== undefined ? { checked: item.checked } : {}),
    ...(item.separatorBefore ? { separatorBefore: true } : {}),
    onSelect: () => void messages.perform(item),
  }));

  const openID = single === undefined || snapshot.selected === single ? snapshot.selected : undefined;
  const conversation = openID ? snapshot.conversations.get(openID) : undefined;
  const style = {
    "--hm-list-width": `${shownWidth}px`,
    ...(chrome.unreadColor ? { "--hm-unread-color": chrome.unreadColor } : {}),
  } as CSSProperties;

  return (
    <AvatarContext.Provider value={store.avatars}>
      <div ref={page} className="hm-page" style={style}>
        {!listless && (
          <div
            className="hm-column"
            // The column waits for this window's width (one host answer), so it never opens at another.
            style={{
              width: shownWidth,
              ...(widthKnown || debug.width !== undefined ? {} : { visibility: "hidden" as const }),
            }}
            // A file dragged over the list goes to the shown conversation, which draws the highlight
            // (HomeSidebarSplitView+Drop.swift); New Message takes none.
            onDragOver={(event) => {
              if (!nav.fileDrop()?.over([...event.dataTransfer.types])) return;
              event.preventDefault();
              event.dataTransfer.dropEffect = "copy";
            }}
            onDragLeave={(event) => {
              if (!event.currentTarget.contains(event.relatedTarget as Node | null)) nav.fileDrop()?.leave();
            }}
            onDrop={(event) => {
              const target = nav.fileDrop();
              if (!target) return;
              target.leave();
              if (event.dataTransfer.files.length === 0) return;
              event.preventDefault();
              target.drop(event.dataTransfer.files);
            }}
          >
            <ConversationList
              model={model}
              width={shownWidth}
              {...(composing ? { selected: DRAFT_ROW } : listSelected ? { selected: listSelected } : {})}
              query={query}
              onQuery={setQuery}
              unreadOnly={unreadOnly}
              onUnreadOnly={setUnreadOnly}
              strings={strings}
              windowControls={lights}
              canPin={snapshot.inboxState}
              onSelect={select}
              onOpen={open}
              onSetPinned={(id, pinned) => void store.setPinned(id, pinned)}
              onArrangePinned={(order) => void store.arrangePinned(order)}
              onMarkRead={(id) => store.markConversationRead(id)}
              onMarkUnread={(id) => void store.setMarkedUnread(id, true)}
              onDelete={(id) =>
                void messages.perform({
                  id: "home.hideConversation",
                  title: t("sidebar.menu.delete"),
                  action: "home.hideConversation",
                  arguments: { conversation: id },
                })
              }
              hostMenu={(id) => messages.menu("row", id)}
              onHostItem={(item) => void messages.perform(item)}
              {...(view.compose ? { draftTitle: t("home.compose.title") } : {})}
              onSelectDraft={() => {
                nav.openCompose();
                nav.requestFocus();
              }}
              onCloseDraft={() => closeNewMessage({ nav, store })}
              requests={view.requests.length}
              onOpenRequests={() => nav.present({ kind: "requests" })}
              {...(facts.note ? { note: facts.note } : {})}
              {...(facts.header ? { header: facts.header } : {})}
              onHeaderBand={onHeaderBand}
              onStartTeammate={startTeammate}
            />
          </div>
        )}
        {!listless && (
          <div
            // The divider is a pointer affordance only, as the native split's: no accessibility element.
            className={`hm-divider${dividerDragging ? " dragging" : ""}`}
            aria-hidden="true"
            onPointerDown={onDividerDown}
          />
        )}
        <main className="hm-detail">
          {detail?.({
            store,
            snapshot,
            ...(conversation ? { conversation } : {}),
            ...(snapshot.me ? { me: snapshot.me } : {}),
            strings,
            host,
            messages,
            chrome,
            ...(openedAt !== undefined ? { openedAt } : {}),
            nav,
            ...(single !== undefined ? { single } : {}),
          })}
          {/* New Message shows: no compose button over it (the native split's `composing`); a single
              conversation's page (a conversation tab) has none. */}
          {single === undefined && !composing && (
            <ContextMenu items={composeMenu} className="hm-menu-host">
              <button
                type="button"
                className="hm-compose"
                style={{ transform: `translate(${composeX}px, ${composeY}px)` }}
                aria-label={t("home.list.newMessage")}
                title={t("home.list.newMessage")}
                onPointerEnter={loadCompose}
                onFocus={loadCompose}
                onClick={compose}
              >
                <HomeIcon name="compose" size={16} />
              </button>
            </ContextMenu>
          )}
        </main>
      </div>
    </AvatarContext.Provider>
  );
}
