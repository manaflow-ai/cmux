// Boots the overlay page (`cmux-page://cmux.overlay/`): what draws over a window's content. The
// native host picks the surface by the route (`#/dialog`); each surface streams its state from the
// host and calls back under `cmux.overlay.`.
import "../shared/desktop";
import { createPageClient } from "../shared/pageClient";
import { mountDialog } from "./dialog";
import "../../ui/ui.css";
import "../shared/pageBase.css";
import "./overlay.css";

const root = document.getElementById("root");
const client = createPageClient();
if (root && client && document.documentElement.dataset.cmuxPage === "overlay") {
  const route = location.hash.replace(/^#\/?/, "");
  if (route === "dialog") mountDialog(root, client);
}
