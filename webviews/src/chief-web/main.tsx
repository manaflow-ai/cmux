import "virtual:cmux-gallery/agent-pane.css";
import "../agent-session/guest/page.css";
import { createRoot } from "react-dom/client";
import { UiProvider } from "../ui/UiProvider";
import { installGuestHost } from "../agent-session/guest/guestHost";
import { followBrowserTheme } from "../agent-session/guest/theme";
import { ChiefWeb } from "./ChiefWeb";

if (import.meta.env.DEV)
  globalThis.__cmuxPaneStrings ??= (await import("../agent-session/acpmux/generated/strings.json")).default;
installGuestHost();
followBrowserTheme();
document.documentElement.dataset.cmuxWebviewKind = "chief-web";
const root = document.getElementById("root")!;
createRoot(root).render(
  <UiProvider container={root}>
    <ChiefWeb />
  </UiProvider>,
);
