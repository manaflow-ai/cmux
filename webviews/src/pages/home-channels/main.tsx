// Boots the channels Home page. The page is always a client of its cmux instance's daemon over the
// daemon WebSocket (DaemonGate, daemonHome.ts): real conversations and instance control, the same
// in every host. Where the daemon comes from:
// - the daemon serves this page itself (http://127.0.0.1:<port>/pages/home-channels/): its own
//   listener, same origin (spec transports.md "App listener and page files");
// - `?daemon=ws://host:port`: any other server of the page bundle (the gallery live server);
// - in the app (cmux-page://cmux.home-channels/): the host verb `cmux.host.credential.load` hands
//   the endpoint and the daemon's credential, and `owner` for this build's Chief conversations
//   (DaemonGate). No Swift serves Home data.
// In the gallery and dev loop (`?mock`) the in-memory mock provider stands in.
import "../shared/desktop";
import { useState } from "react";
import { createRoot } from "react-dom/client";
import { createPageClient, type PageClient } from "../shared/pageClient";
import { PAGE_COMMAND, type PageCommand } from "../shared/pageStreams";
import type { StringTable, Strings } from "../shared/i18n";
import { reloadLocaleScripts } from "../shared/localeScripts";
import { renderLocalized } from "../shared/localizedRoot";
import type { DaemonSocket } from "../shared/daemonSocket";
import { UiProvider, languageDirection } from "../../ui/UiProvider";
import "./paneStrings";
import { APP_ACTION_RUN, HomeChannelsPage, RESTART_SERVER } from "./HomeChannelsPage";
import { MockHomeProvider } from "./mockProvider";
import { HomeChannelsStore, PendingCarry } from "./store";
import { DaemonGate, type DaemonSource, type HostCredential } from "./DaemonGate";
import { DaemonHomeClient } from "./daemonHome";
import { ComposerEdit, hostEdit } from "./composerEdit";
import { QUOTE_COMMAND, quoteSelection } from "./quoteSelection";
import "../shared/pageBase.css";
import "../../ui/ui.css";
import "../../agent-session/acpmux/conversation/conversation.css";
import "./styles.css";
import "./ledger.css";
import { appPopupHost } from "../shared/pagePopupHost";

declare global {
  // eslint-disable-next-line no-var
  var __cmuxStrings: Record<string, Record<string, string>> | undefined;
}

// The page's strings. As shipped (build-pages-web.sh SPLIT_STRINGS), the head's locales/<locale>.js
// scripts have already put English and the app's language in `__cmuxStrings`, so the 21-locale table
// (about 440 KB) is neither in the startup JS nor in the app at all: a shipped page whose locale
// script failed loads the same scripts again (reloadLocaleScripts). The dev server, the gallery and
// tests have no locale scripts and load the whole table.
const table: StringTable = globalThis.__cmuxStrings?.en
  ? globalThis.__cmuxStrings
  : globalThis.__cmuxShippedPages
    ? await reloadLocaleScripts("locales").then(() => (globalThis.__cmuxStrings ??= {}))
    : ((await import("./generated/strings.json")).default as StringTable);

export function mountHomeChannelsPage(
  root: HTMLElement,
  client: PageClient | null = defaultClient(),
): HomeChannelsStore {
  const store = new HomeChannelsStore(client);
  renderLocalized(
    createRoot(root),
    table,
    (strings) => (
      <UiProvider container={root} popupHost={appPopupHost(client)} dir={languageDirection(strings.language)}>
        <HomeChannelsPage store={store} strings={strings} />
      </UiProvider>
    ),
    (strings) => strings.t("page.title"),
  );
  return store;
}

function defaultClient(): PageClient | null {
  const query = new URLSearchParams(location.search);
  return createPageClient(query.has("mock") ? () => new MockHomeProvider() : undefined);
}

/** The page on a cmux instance's daemon: connect (credential or pairing), then the real Home. */
export function mountDaemonHomeChannelsPage(
  root: HTMLElement,
  source: DaemonSource,
  client: PageClient | null = null,
): void {
  // One per mount: each reconnect makes a new store, and unsent messages carry over to it.
  const carry = new PendingCarry();
  // In the app, the composers' Cut, Copy and Paste run as the page view's own edits.
  const edit = client ? hostEdit(client) : undefined;
  // The app's menu on selected message text: Quote in Reply.
  void client
    ?.subscribe<PageCommand>(PAGE_COMMAND, (data) => {
      if (data.command === QUOTE_COMMAND) quoteSelection(document);
    })
    .catch(() => {});
  // In the app, a refused page listener's fix: the app's Restart cmux-tui (it asks first).
  const restart = client
    ? () => void client.call(APP_ACTION_RUN, { action: RESTART_SERVER }).catch(() => undefined)
    : undefined;
  renderLocalized(
    createRoot(root),
    table,
    (strings) => (
      <UiProvider container={root} popupHost={appPopupHost(client)} dir={languageDirection(strings.language)}>
        <ComposerEdit.Provider value={edit}>
          <DaemonGate source={source} strings={strings} restart={restart}>
            {(daemon, _pages, owner) => (
              <div className="hc-daemon">
                <DaemonHome daemon={daemon} owner={owner} host={client} strings={strings} carry={carry} />
              </div>
            )}
          </DaemonGate>
        </ComposerEdit.Provider>
      </UiProvider>
    ),
    (strings) => strings.t("page.title"),
  );
}

/** One store per daemon connection (a render never makes a second one). */
function DaemonHome({
  daemon,
  owner,
  host,
  strings,
  carry,
}: {
  daemon: DaemonSocket;
  /** This build's Chief home's owner, when it serves the local conversations. */
  owner?: DaemonSocket;
  /** The app host: it relays the person's click for a Chief's grant and delete (none in a browser). */
  host: PageClient | null;
  strings: Strings;
  carry: PendingCarry;
}) {
  const [store] = useState(() => new HomeChannelsStore(new DaemonHomeClient(daemon, owner), carry, host));
  // Web links: the page could send them to workspace.open_url, but the daemon takes that operation
  // from a page only with the person's confirmation (page-router gesture list), which this
  // WebSocket cannot present yet. Until the host relays the click with a confirmation
  // (cx-ebm.59.6), the page leaves link clicks to the host.
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
