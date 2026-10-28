// l10n-allow-file: gallery fixtures, not shipped UI.
// The guest page once the share is over (design/chat-multiplayer.md section 3): the link expired,
// the owner ended sharing, the owner removed this guest, or the one-use link was spent. No retry.
import { componentEntry } from "../../gallery/format";
import type { GuestEnded, GuestPageProps } from "./GuestPage";

const ended = (reason: GuestEnded): { props: GuestPageProps } => ({
  props: {
    shareId: "c2hhcmUtZ2FsbGVyeQ",
    redeem: () => new Promise(() => undefined),
    attempt: () => "0".repeat(32),
    socketUrl: "",
    ended: reason,
  },
});

export default componentEntry<GuestPageProps>({
  id: "guest-page.ended",
  title: "Guest page: ended",
  area: "Agent pane",
  keywords: ["multiplayer", "share", "guest", "expired", "revoked", "removed"],
  covers: ["agent-session/guest/GuestPage.tsx"],
  height: 420,
  // A phone browser at narrow.
  widths: { narrow: 390 },
  pane: true,
  load: () => import("./GuestPage").then((module) => module.GuestPage),
  variants: {
    expired: ended("expired"),
    revoked: ended("revoked"),
    removed: ended("kicked"),
    used: ended("used"),
  },
});
