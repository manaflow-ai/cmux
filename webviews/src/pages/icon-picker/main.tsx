// Boots the icon picker page (mount.tsx). In the app the host installs the `cmuxPage` bridge; in a
// browser (`/icon-picker/?mock`) the in-memory mock host stands in.
import { createPageClient, type PageClient } from "../shared/pageClient";
import { mountIconPicker, type MountedPicker } from "./mount";
import { MockIconPickerHost } from "./mockHost";
import "../shared/pageBase.css";
import "../../icon-picker/styles.css";
import "./styles.css";

function defaultClient(): PageClient | null {
  const mock = new URLSearchParams(location.search).has("mock");
  return createPageClient(mock ? () => new MockIconPickerHost() : undefined);
}

performance.mark("icon-picker:boot");
const root = document.getElementById("root");
if (root && document.documentElement.dataset.cmuxPage === "icon-picker") {
  const picker = mountIconPicker(root, defaultClient());
  performance.mark("icon-picker:mounted");
  (globalThis as { cmuxIconPicker?: MountedPicker }).cmuxIconPicker = picker;
}
