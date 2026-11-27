// l10n-allow-file: gallery fixtures, not shipped UI.
// The guest page's open-in-app banner (Leo, 2026-11-07: "if somebody has the app itself, it should be able to
// redirect them to the desktop app for sharing ... by default"): the link asks the cmux app to open
// it. `opening` is the moment the page asks; `opened` is after the app took it, with the browser as a
// second choice. The attempt runs against a fake window here, so the gallery never leaves its page.
import { componentEntry } from "../../gallery/format";
import type { AppOpenWindow } from "./appLink";
import type { OpenInAppProps } from "./OpenInApp";

/** A window where the app never answers (`opening` stays) or takes the link at once, hiding the page (`opened`). */
const fakeWindow = (took: boolean): AppOpenWindow => {
  const listeners = new Map<string, () => void>();
  const document: { visibilityState: DocumentVisibilityState } = { visibilityState: "visible" };
  const hide = () => {
    document.visibilityState = "hidden";
    listeners.get("visibilitychange")?.();
  };
  return {
    location: { assign: () => took && queueMicrotask(hide) },
    document,
    addEventListener: (type, listener) => listeners.set(type, listener),
    removeEventListener: (type) => listeners.delete(type),
    setTimeout: () => 0,
    clearTimeout: () => undefined,
  };
};

const base: OpenInAppProps = {
  appUrl: "cmux://share?link=https%3A%2F%2Fshare.cmux.dev%2Fg%2Fc2hhcmUtZ2FsbGVyeQ#c2VjcmV0LWdhbGxlcnk",
  onContinue: () => undefined,
};

export default componentEntry<OpenInAppProps>({
  id: "guest-page.open-in-app",
  title: "Guest page: open in cmux",
  area: "Agent pane",
  keywords: ["multiplayer", "share", "guest", "open in app", "desktop app", "deep link"],
  covers: ["agent-session/guest/OpenInApp.tsx", "agent-session/guest/appLink.ts"],
  height: 360,
  widths: { narrow: 320, normal: 390 },
  pane: true,
  load: () => import("./OpenInApp").then((module) => module.OpenInApp),
  variants: {
    opening: { props: { ...base, win: fakeWindow(false) }, note: "The page asked the cmux app to open the link." },
    opened: {
      props: { ...base, win: fakeWindow(true) },
      note: "The app took the link; the visitor may still continue in the browser.",
    },
  },
});
