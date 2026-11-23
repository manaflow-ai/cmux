// l10n-allow-file: gallery fixtures, not shipped UI.
// The open-in-app banner over the guest page (cmux-platform#989's review: the join card and whoami start at
// once, the attempt never replaces the page). `pending` is the moment the page asks the app; the join card is
// already there beneath it.
import { componentEntry } from "../../gallery/format";
import type { AppOpenWindow } from "./appLink";
import type { WithOpenInAppProps } from "./OpenInApp";

/** A window where the app never answers: the attempt stays pending. */
const pendingWindow = (): AppOpenWindow => ({
  location: { assign: () => undefined },
  document: { visibilityState: "visible" },
  addEventListener: () => undefined,
  removeEventListener: () => undefined,
  setTimeout: () => 0,
  clearTimeout: () => undefined,
});

const joinCard = (
  <main className="guest-card">
    <h1 className="guest-card__title">Join the chat</h1>
    <div className="guest-join">
      <button className="guest-join__button" type="button">
        Join as Capture Guest
      </button>
    </div>
  </main>
);

export default componentEntry<WithOpenInAppProps>({
  id: "guest-page.open-in-app-over-page",
  title: "Guest page: open in cmux over the join card",
  area: "Agent pane",
  keywords: ["multiplayer", "share", "guest", "open in app", "banner", "join"],
  covers: ["agent-session/guest/OpenInApp.tsx", "agent-session/guest/guest.css"],
  height: 420,
  widths: { narrow: 320, normal: 390 },
  pane: true,
  load: () => import("./OpenInApp").then((module) => module.WithOpenInApp),
  variants: {
    pending: {
      props: {
        appUrl: "cmux://share?link=https%3A%2F%2Fshare.cmux.dev%2Fg%2Fc2hhcmUtZ2FsbGVyeQ#c2VjcmV0LWdhbGxlcnk",
        onChooseBrowser: () => undefined,
        win: pendingWindow(),
        children: joinCard,
      },
      note: "The page asked the cmux app; the join card is already there, and the banner takes no space.",
    },
  },
});
