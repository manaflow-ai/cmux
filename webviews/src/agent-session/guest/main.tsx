// The guest page's entry (vite.config.guest-page.mjs; scripts/cmux-next/build-guest-page-web.sh
// builds it for the room to serve at /g/<share_id>). The page carries the agent pane's own
// stylesheet, the one the app ships and the gallery draws (dev-server/galleryHost.ts), so the
// transcript looks as the owner sees it.
import "virtual:cmux-gallery/agent-pane.css";
import "./page.css";
import { createRoot } from "react-dom/client";
import { UiProvider } from "../../ui/UiProvider";
import { AcpmuxDirectClient, nextFrame } from "../acpmux/direct";
import { GuestPage } from "./GuestPage";
import { attemptId, joinedBefore, redeemOverFetch, rememberJoined, takeGuestLink } from "./redeem";
import { followBrowserTheme } from "./theme";

// The built page loads its strings from locales/ before this module (the build script's loader);
// the dev server has none and reads the whole table.
if (import.meta.env.DEV) globalThis.__cmuxPaneStrings ??= (await import("../acpmux/generated/strings.json")).default;

AcpmuxDirectClient.scheduleFrame = nextFrame;
document.documentElement.dataset.cmuxWebviewKind = "guest-page";
followBrowserTheme();

const storage = window.sessionStorage;
// Read first: this takes the secret out of the address bar before anything else runs.
const link = takeGuestLink(window.location, window.history, storage);
const root = document.getElementById("root")!;
// A path that names no share opens the join page with Join off ("This link is incomplete").
const shareId = link?.shareId ?? "";
const socketUrl = `${location.protocol === "http:" ? "ws:" : "wss:"}//${location.host}/v1/chat-shares/${encodeURIComponent(shareId)}/guest`;
createRoot(root).render(
  <UiProvider container={root}>
    <GuestPage
      shareId={shareId}
      secret={link?.secret}
      joined={!!link && joinedBefore(shareId, storage)}
      redeem={redeemOverFetch()}
      attempt={() => attemptId(shareId, storage)}
      onJoined={() => rememberJoined(shareId, storage)}
      socketUrl={socketUrl}
    />
  </UiProvider>,
);
