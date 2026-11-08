// Boots the workspace group editor page (mount.tsx). In the app the host installs the `cmuxPage`
// bridge; in a browser (`/group-editor/?mock`) the in-memory mock host stands in.
// DESKTOP-FEEL (R139): the shared desktop layer loads first.
import "../shared/desktop";
import { createPageClient, type PageClient } from "../shared/pageClient";
import { mountGroupEditor, type MountedGroupEditor } from "./mount";
import { MockGroupEditorHost } from "./mockHost";
import "../shared/pageBase.css";
import "./styles.css";

function defaultClient(): PageClient | null {
  const mock = new URLSearchParams(location.search).has("mock");
  return createPageClient(mock ? () => new MockGroupEditorHost() : undefined);
}

const root = document.getElementById("root");
if (root && document.documentElement.dataset.cmuxPage === "group-editor") {
  const editor = mountGroupEditor(root, defaultClient());
  (globalThis as { cmuxGroupEditor?: MountedGroupEditor }).cmuxGroupEditor = editor;
}
