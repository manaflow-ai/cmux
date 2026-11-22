// Boots the docked Home's Messages page. Like the Channels page it is a client of its cmux
// instance's daemon over the daemon WebSocket, through the same data layer (home-channels/store.ts,
// daemonHome.ts and cloudHome.ts behind DaemonGate). Where the daemon comes from:
// - `?daemon=ws://host:port`: any server of the page bundle (the gallery live server);
// - in the app (cmux-page://cmux.home-messages/): the host verb `cmux.host.credential.load` hands
//   the endpoint and the daemon's credential, and `owner` for this build's Chief conversations.
// The host adds only what the app knows (host.ts: the row and compose menus, the traffic lights).
// In the gallery and dev loop (`?mock`) the Channels page's in-memory mock provider stands in.
import "../shared/desktop";
import { useState } from "react";
import { createRoot } from "react-dom/client";
import { createPageClient, type PageClient } from "../shared/pageClient";
import { createStrings, type Strings } from "../shared/i18n";
import type { DaemonSocket } from "../shared/daemonSocket";
import { UiProvider, languageDirection } from "../../ui/UiProvider";
import { appPopupHost } from "../shared/pagePopupHost";
import { MockHomeProvider } from "../home-channels/mockProvider";
import { HomeChannelsStore, PendingCarry } from "../home-channels/store";
import { DaemonGate, type DaemonSource, type HostCredential } from "../home-channels/DaemonGate";
import { DaemonHomeClient } from "../home-channels/daemonHome";
import { MessagesApp } from "./App";
import { noMessagesHost, pageMessagesHost } from "./host";
import type { MessagesDetail, MessagesHost } from "./types";
import table from "./generated/strings.json";
import "../shared/pageBase.css";
import "../../ui/ui.css";
import "./styles.css";
import "./list/list.css";

/** The page on an in-memory provider (the gallery, `?mock`). */
export function mountMockMessagesPage(root: HTMLElement, detail?: MessagesDetail): HomeChannelsStore {
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
        {...(detail ? { detail } : {})}
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
  detail?: MessagesDetail,
): void {
  const strings = createStrings(table);
  document.title = strings.t("home.title");
  // One per mount: each reconnect makes a new store, and unsent messages carry over to it.
  const carry = new PendingCarry();
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
            {...(detail ? { detail } : {})}
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
  detail,
}: {
  daemon: DaemonSocket;
  owner?: DaemonSocket;
  host: PageClient | null;
  messages: MessagesHost;
  strings: Strings;
  carry: PendingCarry;
  detail?: MessagesDetail;
}) {
  const [store] = useState(() => new HomeChannelsStore(new DaemonHomeClient(daemon, owner), carry, host));
  return (
    <MessagesApp
      store={store}
      strings={strings}
      host={host}
      messages={messages}
      {...(detail ? { detail } : {})}
      widthStorage={globalThis.localStorage ?? null}
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
