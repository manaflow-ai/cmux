// The guest page's entry (vite.config.guest-page.mjs; scripts/cmux-next/build-guest-page-web.sh
// builds it for the room to serve at /g/<share_id>, and at /i/<share_id> for an invite). The page carries the agent pane's own
// stylesheet, the one the app ships and the gallery draws (dev-server/galleryHost.ts), so the
// transcript looks as the owner sees it: the first frame's part here, the rest beside the
// transcript's chunk (transcriptSheet.ts).
import "./firstFrame.css";
import "./page.css";
import { createRoot } from "react-dom/client";
import { UiProvider } from "../../ui/UiProvider";
import { GuestPage, startGuestPage } from "./GuestPage";
import { WithOpenInApp } from "./OpenInApp";
import { appLinkUrl, appScheme, chooseBrowser, offersApp } from "./appLink";
import {
  acceptOverFetch,
  attemptId,
  joinedAs,
  joinedName,
  joinedRole,
  redeemOverFetch,
  rememberJoined,
  takeGuestLink,
  whoamiOverFetch,
} from "./redeem";
import { followBrowserTheme } from "./theme";

// The built page loads its strings from locales/ before this module (the build script's loader);
// the dev server has none and reads the whole table.
if (import.meta.env.DEV) globalThis.__cmuxPaneStrings ??= (await import("../acpmux/generated/strings.json")).default;

document.documentElement.dataset.cmuxWebviewKind = "guest-page";
followBrowserTheme();

const storage = window.sessionStorage;
// Read first: this takes the secret out of the address bar before anything else runs.
const link = takeGuestLink(window.location, window.history, storage);
// The transcript's chunk (GuestTranscript.tsx) loads beside the first frame: a joined guest needs it
// for the room's snapshot, a new one after Join. Its no-owner host is installed as it arrives,
// before anything from it draws (GuestPage.tsx startGuestPage).
if (link) startGuestPage(() => import("./transcriptSheet"));
const root = document.getElementById("root")!;
// A path that names no share opens the join page with Join off ("This link is incomplete").
const shareId = link?.shareId ?? "";
const socketUrl = `${location.protocol === "http:" ? "ws:" : "wss:"}//${location.host}/v1/chat-shares/${encodeURIComponent(shareId)}/guest`;
const guestId = link ? joinedAs(shareId, storage, link.invite === true) : undefined;
// The cmux app first, when it is installed (appLink.ts): never inside the app's own web view
// (`?in_app=1`), after the visitor chose the browser, or once this tab joined.
const scheme = appScheme(window.location);
const appUrl =
  link && scheme && offersApp(window.location, storage, shareId, guestId !== undefined)
    ? appLinkUrl(scheme, window.location.origin, link)
    : undefined;

// The guest page mounts at once; the app attempt is a banner over it (OpenInApp.tsx), never a step before it.
function Guest() {
  return (
    <WithOpenInApp appUrl={appUrl} onChooseBrowser={() => chooseBrowser(storage, shareId)}>
      <GuestPage
        shareId={shareId}
        secret={link?.secret}
        guestId={guestId}
        name={link ? joinedName(shareId, storage) : undefined}
        role={link ? joinedRole(shareId, storage, link.invite === true) : undefined}
        storage={storage}
        redeem={redeemOverFetch()}
        invite={link?.invite === true}
        accept={acceptOverFetch()}
        whoami={whoamiOverFetch()}
        attempt={() => attemptId(shareId, storage)}
        onJoined={(guestId, name, role, via) => rememberJoined(shareId, guestId, storage, name, role, via)}
        socketUrl={socketUrl}
      />
    </WithOpenInApp>
  );
}

createRoot(root).render(
  <UiProvider container={root}>
    <Guest />
  </UiProvider>,
);
