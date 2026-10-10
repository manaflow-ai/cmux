// Boots the channels Home page (cmux-page://cmux.home-channels/). In the app the host installs the
// `cmuxPage` bridge and serves `cmux.home.*` (HomeChannelsPageProvider.swift); in the browser dev
// loop (`/home-channels/?mock`) the in-memory mock provider stands in for the Home owners.
import "../shared/desktop";
import { createRoot } from "react-dom/client";
import { createPageClient, type PageClient } from "../shared/pageClient";
import { createStrings } from "../shared/i18n";
import { HomeChannelsPage } from "./HomeChannelsPage";
import table from "./generated/strings.json";
import { MockHomeProvider } from "./mockProvider";
import { HomeChannelsStore } from "./store";
import "../shared/pageBase.css";
import "../../agent-session/acpmux/conversation/conversation.css";
import "./styles.css";

export function mountHomeChannelsPage(
  root: HTMLElement,
  client: PageClient | null = defaultClient(),
): HomeChannelsStore {
  const store = new HomeChannelsStore(client);
  const strings = createStrings(table);
  document.title = strings.t("page.title");
  createRoot(root).render(<HomeChannelsPage store={store} strings={strings} />);
  return store;
}

function defaultClient(): PageClient | null {
  const query = new URLSearchParams(location.search);
  return createPageClient(query.has("mock") ? () => new MockHomeProvider() : undefined);
}

const root = document.getElementById("root");
if (root && document.documentElement.dataset.cmuxPage === "home-channels") mountHomeChannelsPage(root);
