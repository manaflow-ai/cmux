// The guest page's entry (vite.config.guest-page.mjs; scripts/cmux-next/build-guest-page-web.sh
// builds it for the room to serve at /g/<share_id>, and at /i/<share_id> for an invite). The page carries the agent pane's own
// stylesheet, the one the app ships and the gallery draws (dev-server/galleryHost.ts), so the
// transcript looks as the owner sees it.
import "virtual:cmux-gallery/agent-pane.css";
import "./page.css";
import { useState } from "react";
import { createRoot } from "react-dom/client";
import { UiProvider } from "../../ui/UiProvider";
import { AcpmuxDirectClient, nextFrame } from "../acpmux/direct";
import { GuestPage } from "./GuestPage";
import { OpenInApp } from "./OpenInApp";
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
} from "./redeem";
import { followBrowserTheme } from "./theme";
import { installGuestHost } from "./guestHost";

// The built page loads its strings from locales/ before this module (the build script's loader);
// the dev server has none and reads the whole table.
if (import.meta.env.DEV) globalThis.__cmuxPaneStrings ??= (await import("../acpmux/generated/strings.json")).default;

// No owner host, before anything can ask one (guestHost.ts).
installGuestHost();
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
const guestId = link ? joinedAs(shareId, storage, link.invite === true) : undefined;
// The cmux app first, when it is installed (appLink.ts): never inside the app's own web view
// (`?in_app=1`), after the visitor chose the browser, or once this tab joined.
const scheme = appScheme(window.location);
const appUrl =
  link && scheme && offersApp(window.location, storage, shareId, guestId !== undefined)
    ? appLinkUrl(scheme, window.location.origin, link)
    : undefined;

function Guest() {
  const [inBrowser, setInBrowser] = useState(appUrl === undefined);
  if (!inBrowser && appUrl)
    return (
      <OpenInApp
        appUrl={appUrl}
        onContinue={() => {
          chooseBrowser(storage, shareId);
          setInBrowser(true);
        }}
      />
    );
  return (
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
      attempt={() => attemptId(shareId, storage)}
      onJoined={(guestId, name, role, via) => rememberJoined(shareId, guestId, storage, name, role, via)}
      socketUrl={socketUrl}
    />
  );
}

createRoot(root).render(
  <UiProvider container={root}>
    <Guest />
  </UiProvider>,
);
