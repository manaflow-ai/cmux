// The Messages page's shell: the conversation list in a resizable column on the left and the detail
// slot on the right (the transcript and composer, the sheets and the in-chat cards plug in there),
// with the chat's compose button over the slot's top-left, as the native Home lays them out
// (`HomeSidebarSplitView`, `HomeChatColumnView`). It reads the Channels data layer's store and keeps
// only view state of its own: the search, the Unread filter and the column's width.
//
// - The column is 320 pt to start, between 76 pt (avatars only) and the smaller of half the page and
//   what leaves the transcript 280 pt. A drag of the divider sets it (kept for the next open); a
//   double-click puts it back.
// - A narrow page that would squeeze a list of one conversation to avatars folds the column away.
// - The window's traffic lights are the host's value: the list's header and compose keep clear.
import {
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
import { ConversationList, DRAFT_ROW } from "./list/ConversationList";
import { clampWidth, COMPACT_BELOW, HEADER, WIDTH } from "./list/layout";
import { holdsOneConversation, listModel } from "./list/model";
import { MessagesNav } from "./nav";
import { usePageCommands } from "./pageCommands";
import type { HostMenuItem, MessagesChrome, MessagesDetail, MessagesHost } from "./types";

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
  /** Where the column's width is kept (null: not kept, the gallery). */
  widthStorage?: Storage | null;
  /** The one conversation a conversation tab or the Chief panel shows (single.ts): no list column,
   * no compose button, and the page keeps that conversation open. */
  single?: string;
}

const WIDTH_KEY = "cmux.home.sidebarWidth";
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
      listModel(snapshot.conversations, {
        ...(me ? { me } : {}),
        query,
        unreadOnly,
        now,
        language,
        words,
        activity: snapshot.activity,
      }),
    [snapshot.conversations, snapshot.activity, me, query, unreadOnly, now, language, words],
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
  const wanted = own ?? WIDTH.standard;
  const listWidth = clampWidth(wanted, pageWidth - WIDTH.divider);
  const folded =
    holdsOneConversation(model, { requests: view.requests.length }) &&
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

  const keep = (width: number | undefined) => {
    setOwn(width);
    if (width === undefined) widthStorage?.removeItem(WIDTH_KEY);
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
    const left = page.current?.getBoundingClientRect().left ?? 0;
    const move = (e: PointerEvent) => keep(clampWidth(e.clientX - left, pageWidth - WIDTH.divider));
    const up = () => {
      divider.removeEventListener("pointermove", move);
      divider.removeEventListener("pointerup", up);
      divider.removeEventListener("pointercancel", up);
    };
    divider.addEventListener("pointermove", move);
    divider.addEventListener("pointerup", up);
    divider.addEventListener("pointercancel", up);
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
  const shown = !composing && snapshot.selected ? snapshot.selected : undefined;
  const selection = useMemo(
    () => (shown ? { conversation: shown, ...(snapshot.highlight ? { message: snapshot.highlight } : {}) } : null),
    [shown, snapshot.highlight],
  );
  usePageCommands(host, { store, nav, model }, selection);

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
          <div className="hm-column" style={{ width: shownWidth }}>
            <ConversationList
              model={model}
              width={shownWidth}
              {...(composing ? { selected: DRAFT_ROW } : snapshot.selected ? { selected: snapshot.selected } : {})}
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
              onCloseDraft={() => nav.closeCompose()}
              requests={view.requests.length}
              onOpenRequests={() => nav.present({ kind: "requests" })}
            />
          </div>
        )}
        {!listless && (
          <div
            // The divider is a pointer affordance only, as the native split's: no accessibility element.
            className="hm-divider"
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
          {single === undefined && (
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
