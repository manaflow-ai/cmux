// Boots the channels Home page. The page is always a client of its cmux instance's daemon over the
// daemon WebSocket (DaemonGate, daemonHome.ts): real conversations and instance control, the same
// in every host. Where the daemon comes from:
// - the daemon serves this page itself (http://127.0.0.1:<port>/pages/home-channels/): its own
//   listener, same origin (spec transports.md "App listener and page files");
// - `?daemon=ws://host:port`: any other server of the page bundle (the gallery live server);
// - in the app (cmux-page://cmux.home-channels/): the host verb `cmux.host.credential.load` hands
//   the endpoint and the daemon's credential. No Swift serves Home data.
// In the gallery and dev loop (`?mock`) the in-memory mock provider stands in.
import "../shared/desktop";
import { useState } from "react";
import { createRoot } from "react-dom/client";
import { createPageClient, type PageClient } from "../shared/pageClient";
import { createStrings, type Strings } from "../shared/i18n";
import type { DaemonSocket } from "../shared/daemonSocket";
import { UiProvider, languageDirection } from "../../ui/UiProvider";
import { HomeChannelsPage } from "./HomeChannelsPage";
import table from "./generated/strings.json";
import { MockHomeProvider } from "./mockProvider";
import { HomeChannelsStore } from "./store";
import { DaemonGate, InstanceBar, type DaemonSource, type HostCredential } from "./DaemonGate";
import { DaemonHomeClient } from "./daemonHome";
import "../shared/pageBase.css";
import "../../ui/ui.css";
import "../../agent-session/acpmux/conversation/conversation.css";
import "./styles.css";
import { appPopupHost } from "../shared/pagePopupHost";

export function mountHomeChannelsPage(
  root: HTMLElement,
  client: PageClient | null = defaultClient(),
): HomeChannelsStore {
  const store = new HomeChannelsStore(client);
  const strings = createStrings(table);
  document.title = strings.t("page.title");
  createRoot(root).render(
    <UiProvider container={root} popupHost={appPopupHost(client)} dir={languageDirection(strings.language)}>
      <HomeChannelsPage store={store} strings={strings} />
    </UiProvider>,
  );
  return store;
}

function defaultClient(): PageClient | null {
  const query = new URLSearchParams(location.search);
  return createPageClient(query.has("mock") ? () => new MockHomeProvider() : undefined);
}

/** The page on a cmux instance's daemon: connect (credential or pairing), then the real Home. */
export function mountDaemonHomeChannelsPage(root: HTMLElement, source: DaemonSource, client: PageClient | null = null): void {
  const strings = createStrings(table);
  document.title = strings.t("page.title");
  createRoot(root).render(
    <UiProvider container={root} popupHost={appPopupHost(client)} dir={languageDirection(strings.language)}>
      <DaemonGate source={source} strings={strings}>
        {(daemon, pages) => (
          <div className="hc-daemon">
            <InstanceBar daemon={daemon} strings={strings} pageUrl={pages ? `${pages}home-channels/` : undefined} />
            <DaemonHome daemon={daemon} strings={strings} />
          </div>
        )}
      </DaemonGate>
    </UiProvider>,
  );
}

/** One store per daemon connection (a render never makes a second one). */
function DaemonHome({ daemon, strings }: { daemon: DaemonSocket; strings: Strings }) {
  const [store] = useState(() => new HomeChannelsStore(new DaemonHomeClient(daemon)));
  return <HomeChannelsPage store={store} strings={strings} />;
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

/** Served by the daemon's own listener: its WebSocket is this page's origin. */
function servedByDaemon(): string | null {
  if (location.protocol !== "http:" && location.protocol !== "https:") return null;
  if (!location.pathname.startsWith("/pages/home-channels/")) return null;
  return `${location.protocol === "https:" ? "wss" : "ws"}://${location.host}/`;
}

const root = document.getElementById("root");
if (root && document.documentElement.dataset.cmuxPage === "home-channels") {
  const query = new URLSearchParams(location.search);
  const endpoint = daemonEndpoint() ?? (query.has("mock") ? null : servedByDaemon());
  const bridge = query.has("mock") ? null : createPageClient();
  if (endpoint) mountDaemonHomeChannelsPage(root, { kind: "url", url: endpoint });
  else if (bridge) {
    // In the app: the host hands the endpoint and its daemon's credential on every (re)connect.
    const load = () => bridge.call<HostCredential>("cmux.host.credential.load", {});
    mountDaemonHomeChannelsPage(root, { kind: "host", load }, bridge);
  } else mountHomeChannelsPage(root);
}
