// Boots the Chat Colors page (`cmux-page://cmux.home-chat-colors/`, mount.tsx). In the app the host
// installs the `cmuxPage` bridge; in a plain browser there is no host and the panel draws empty.
// DESKTOP-FEEL (R139): the shared desktop layer loads first.
import "../shared/desktop";
import { createPageClient } from "../shared/pageClient";
import { mountChatColors } from "./mount";
import "../shared/pageBase.css";
import "../../ui/ui.css";
import "./styles.css";

const root = document.getElementById("root");
if (root && document.documentElement.dataset.cmuxPage === "home-chat-colors") {
  mountChatColors(root, createPageClient());
}
