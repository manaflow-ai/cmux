// Boots the channels Home page (cmux-page://cmux.home-channels/). With `?daemon=ws://host:port` the
// page is a client of that cmux instance's daemon over its WebSocket (DaemonGate, daemonHome.ts):
// real conversations and instance control, the same in any browser or host. In the app today the
// host installs the `cmuxPage` bridge (HomeChannelsPageProvider.swift, removed by slice 2); in the
// gallery and dev loop (`?mock`) the in-memory mock provider stands in.
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
import { DaemonGate, InstanceBar } from "./DaemonGate";
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
export function mountDaemonHomeChannelsPage(root: HTMLElement, url: string): void {
  const strings = createStrings(table);
  document.title = strings.t("page.title");
  createRoot(root).render(
    <UiProvider container={root} popupHost={appPopupHost(null)} dir={languageDirection(strings.language)}>
      <DaemonGate url={url} strings={strings}>
        {(daemon) => (
          <div className="hc-daemon">
            <InstanceBar daemon={daemon} strings={strings} />
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

const root = document.getElementById("root");
if (root && document.documentElement.dataset.cmuxPage === "home-channels") {
  const endpoint = daemonEndpoint();
  if (endpoint) mountDaemonHomeChannelsPage(root, endpoint);
  else mountHomeChannelsPage(root);
}
