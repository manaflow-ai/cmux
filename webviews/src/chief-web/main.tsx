// The agent pane's stylesheet, split as on the guest page (vite.config.chief-web.mjs): the first
// frame's sheets (the page base, glass, the pane's palette) with this entry, and the rest (the
// transcript's rows, code, diffs, Tailwind) beside it, so the header and composer wait only on what
// they draw.
import "../agent-session/guest/firstFrame.css";
import "../agent-session/guest/page.css";
import { createRoot } from "react-dom/client";
import { UiProvider } from "../ui/UiProvider";
import { installGuestHost } from "../agent-session/guest/guestHost";
import { followBrowserTheme } from "../agent-session/guest/theme";
import { installFocusModality } from "../ui/focusModality";
import { paneLanguage, setPaneLanguage } from "../agent-session/acpmux/i18n";
import { ChiefWeb } from "./ChiefWeb";

if (import.meta.env.DEV) {
  globalThis.__cmuxPaneStrings ??= (await import("../agent-session/acpmux/generated/strings.json")).default;
  setPaneLanguage(paneLanguage());
}
// The rest of the pane sheet, fetched at once beside the first frame; the transcript's chunk waits
// for it too (ChiefWeb.tsx loadChiefTranscript).
void import("../agent-session/guest/transcriptSheet").catch(() => {});
installGuestHost();
followBrowserTheme();
// FOCUS-RING: rings only for focus a key moved, as in the app (ui/focusModality.ts).
installFocusModality();
document.documentElement.dataset.cmuxWebviewKind = "chief-web";
const root = document.getElementById("root")!;
createRoot(root).render(
  <UiProvider container={root}>
    <ChiefWeb />
  </UiProvider>,
);
