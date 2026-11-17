// Boots the docked Home's Messages page. Like the Channels page it is a client of its cmux
// instance's daemon over the daemon WebSocket, through the same data layer (home-channels/store.ts,
// daemonHome.ts and cloudHome.ts behind DaemonGate). Where the daemon comes from:
// - `?daemon=ws://host:port`: any server of the page bundle (the gallery live server);
// - in the app (cmux-page://cmux.home-messages/): the host verb `cmux.host.credential.load` hands
//   the endpoint and the daemon's credential, and `owner` for this build's Chief conversations.
// The host adds only what the app knows (host.ts: the row and compose menus, the traffic lights).
// In the gallery and dev loop (`?mock`) the Channels page's in-memory mock provider stands in.
import "../shared/desktop";
// Before any part that reads the pane's table: the Channels rows' keys, the mic's and the chips'.
import "./paneStrings";
import { useState } from "react";
import { createRoot } from "react-dom/client";
import { createPageClient, type PageClient } from "../shared/pageClient";
import { holdWebSwap } from "../shared/webSwap";
import { settle, SETTLE_OP } from "./settle";
import { createStrings, type Strings } from "../shared/i18n";
import type { DaemonSocket } from "../shared/daemonSocket";
import { UiProvider, languageDirection } from "../../ui/UiProvider";
import { appPopupHost } from "../shared/pagePopupHost";
import { MockHomeProvider } from "../home-channels/mockProvider";
import { HomeChannelsStore, PendingCarry } from "../home-channels/store";
import { DaemonGate, type DaemonSource, type HostCredential } from "../home-channels/DaemonGate";
import { DaemonHomeClient } from "../home-channels/daemonHome";
import { MessagesApp } from "./App";
import { MessagesDetail as MessagesDetailView } from "./detail/MessagesDetail";
import { noMessagesHost, pageAttachmentKeeper, pageDraftKeeper, pageMessagesHost } from "./host";
import { KeptPendingCarry, pageOutboxKeeper } from "./outbox";
import { MessagesNav } from "./nav";
import { singleConversation } from "./single";
import type { MessagesDetail, MessagesHost } from "./types";
import table from "./generated/strings.json";
import "../shared/pageBase.css";
import "../../ui/ui.css";
import "./styles.css";
import "./list/list.css";

/** The detail slot the page mounts: the transcript, New Message, the sheets and the cards. */
const pageDetail: MessagesDetail = (props) => <MessagesDetailView {...props} />;

/** The page on an in-memory provider (the gallery, `?mock`). */
export function mountMockMessagesPage(root: HTMLElement, detail: MessagesDetail = pageDetail): HomeChannelsStore {
  const store = new HomeChannelsStore(new MockHomeProvider());
  const strings = createStrings(table);
  document.title = strings.t("home.title");
  createRoot(root).render(
    <UiProvider container={root} popupHost={appPopupHost(null)} dir={languageDirection(strings.language)}>
      <MessagesApp
        store={store}
        strings={strings}
        host={null}
        messages={noMessagesHost}
        detail={detail}
        widthStorage={null}
      />
    </UiProvider>,
  );
  return store;
}

/** The page on a cmux instance's daemon: connect (credential or pairing), then the list. */
export function mountMessagesPage(
  root: HTMLElement,
  source: DaemonSource,
  client: PageClient | null,
  detail: MessagesDetail = pageDetail,
): void {
  const strings = createStrings(table);
  document.title = strings.t("home.title");
  const single = singleConversation(location.hash);
  // One per mount: each reconnect makes a new store, and unsent messages carry over to it.
  // The app keeps them across launches too (outbox.ts): a relaunch shows a send it never took.
  // One per mount too: a reconnect keeps the drafts, the files, New Message and what showed.
  const nav = new MessagesNav(
    client ? pageDraftKeeper(client) : undefined,
    client ? pageAttachmentKeeper(client) : undefined,
  );
  // A sent file's kept bytes pass from its tray to the outbox once the outbox keeps the send.
  const carry = client
    ? new KeptPendingCarry(pageOutboxKeeper(client), (hashes) => nav.attachments.handedOver(hashes))
    : new PendingCarry();
  if (carry instanceof KeptPendingCarry) void carry.load();
  // WEB-SWAP: a web update's reload waits while anything lives only in this page: a draft, a staged
  // file or a send the app has not said it holds (nav.ts, attachmentDrafts.ts, outbox.ts). Each
  // composer's own hold ends with it; this one is the page's whole life.
  const heldAlone = () => nav.holdReason() ?? (carry instanceof KeptPendingCarry ? carry.holdReason() : null);
  holdWebSwap(heldAlone);
  // Before the app ends this document (a conversation tab or the Chief panel closing), everything
  // held alone goes to its owner first (settle.ts).
  client?.handle(SETTLE_OP, (params) => settle(() => nav.flushDrafts(), heldAlone, params));
  void nav.loadDrafts();
  void nav.attachments.load();
  // The page's whole life: what was typed in the last pause is kept before the document ends.
  window.addEventListener("pagehide", () => nav.flushDrafts());
  const messages = client ? pageMessagesHost(client) : noMessagesHost;
  createRoot(root).render(
    <UiProvider container={root} popupHost={appPopupHost(client)} dir={languageDirection(strings.language)}>
      <DaemonGate source={source} strings={strings}>
        {(daemon, _pages, owner) => (
          <DaemonMessages
            daemon={daemon}
            {...(owner ? { owner } : {})}
            host={client}
            messages={messages}
            strings={strings}
            carry={carry}
            nav={nav}
            detail={detail}
            {...(single ? { single } : {})}
          />
        )}
      </DaemonGate>
    </UiProvider>,
  );
}

/** One store per daemon connection (a render never makes a second one). */
function DaemonMessages({
  daemon,
  owner,
  host,
  messages,
  strings,
  carry,
  nav,
  detail,
  single,
}: {
  daemon: DaemonSocket;
  owner?: DaemonSocket;
  host: PageClient | null;
  messages: MessagesHost;
  strings: Strings;
  carry: PendingCarry;
  nav: MessagesNav;
  detail: MessagesDetail;
  single?: string;
}) {
  const [store] = useState(() => {
    const made = new HomeChannelsStore(new DaemonHomeClient(daemon, owner), carry, host);
    // In the app the app opens the default conversation (its preferred Chief), on the first load
    // as later; a reconnect reopens what showed.
    if (host) made.pickDefault = (conversations) => nav.restorable(conversations);
    // Read receipts follow the transcript on screen (New Message hides it), as natively.
    made.readsOnView = true;
    return made;
  });
  return (
    <MessagesApp
      store={store}
      strings={strings}
      host={host}
      messages={messages}
      detail={detail}
      nav={nav}
      widthStorage={globalThis.localStorage ?? null}
      {...(single ? { single } : {})}
    />
  );
}

/** The daemon endpoint in the query (`?daemon=ws://127.0.0.1:7681`): only ws/wss URLs. */
function daemonEndpoint(): string | null {
  const value = new URLSearchParams(location.search).get("daemon");
  if (!value) return null;
  try {
    const url = new URL(value);
    return url.protocol === "ws:" || url.protocol === "wss:" ? url.toString() : null;
  } catch {
    return null;
  }
}

const root = document.getElementById("root");
if (root && document.documentElement.dataset.cmuxPage === "home-messages") {
  const query = new URLSearchParams(location.search);
  const endpoint = daemonEndpoint();
  const bridge = query.has("mock") ? null : createPageClient();
  if (endpoint) mountMessagesPage(root, { kind: "url", url: endpoint }, null);
  else if (bridge) {
    // In the app: the host hands the endpoint and its daemon's credential on every (re)connect.
    const load = () => bridge.call<HostCredential>("cmux.host.credential.load", {});
    mountMessagesPage(root, { kind: "host", load }, bridge);
  } else mountMockMessagesPage(root);
}
