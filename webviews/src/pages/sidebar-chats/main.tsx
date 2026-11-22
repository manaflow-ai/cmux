// Boots a sidebar chat history block (`cmux-page://cmux.sidebar-chats/`, mount.tsx). The sidebar's list
// holds one such page per block it shows (Pinned, Earlier; SidebarChatHistoryHost.swift), transparent in
// the list's gap for it. In a browser (`/sidebar-chats/?mock`) the in-memory mock host stands in.
import "../shared/desktop";
import { createPageClient, type PageClient } from "../shared/pageClient";
import { createStrings } from "../shared/i18n";
import { mountSidebarChats, type MountedSidebarChats } from "./mount";
import { MockSidebarChatsHost } from "./mockHost";
import table from "./generated/strings.json";
import "../shared/pageBase.css";
import "./styles.css";

function defaultClient(): PageClient | null {
  const mock = new URLSearchParams(location.search).has("mock");
  return createPageClient(mock ? () => new MockSidebarChatsHost() : undefined);
}

const root = document.getElementById("root");
if (root && document.documentElement.dataset.cmuxPage === "sidebar-chats") {
  const strings = createStrings(table);
  document.documentElement.lang = strings.language;
  const chats = mountSidebarChats(root, defaultClient(), {
    pinned: strings.t("sidebar.section.pinned"),
    earlier: strings.t("sidebar.chatHistory.earlier"),
    showMore: strings.t("sidebar.chatHistory.showMore"),
    loading: strings.t("sidebar.chatHistory.loading"),
  });
  (globalThis as { cmuxSidebarChats?: MountedSidebarChats }).cmuxSidebarChats = chats;
}
