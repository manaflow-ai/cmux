// l10n-allow-file: gallery entry notes, not shipped UI.
// Session Info's three places by the pane's width (SessionInfo.tsx sessionInfoStage; Leo, 2026-11-03:
// "we previously had all that behaviour logic going from not affecting layout at all -> gradually
// pushing into the chat layout -> overlay"). At 1600px the right gutter holds the panel and the chat
// does not move; at 1200px it pushes into the chat by only what the gutter lacks (pushedRoom); at 740px
// it takes its whole width and narrows so the chat keeps 440px. Under 648px it lies over the chat
// (agent-pane.session-info-narrow-pane).
import { componentEntry } from "../../../gallery/format";
import { setHeaderState } from "../header/headerState";
import { setSessionInfoOpen } from "./sessionInfoState";
import { GalleryPane } from "./SessionInfoSurfaces.gallery";

export default componentEntry<{ surface: "transcript" }>({
  id: "agent-pane.session-info-stages",
  title: "Session Info floats, then pushes the chat gradually, by the pane's width",
  area: "Agent pane",
  pane: true,
  height: 640,
  widths: { narrow: 740, normal: 1200, wide: 1600 },
  covers: [
    "agent-session/acpmux/session-info/SessionInfo.tsx#sessionInfoStage",
    "agent-session/acpmux/session-info/SessionInfo.tsx#pushedRoom",
  ],
  load: async () => {
    setHeaderState({ inspector: true });
    setSessionInfoOpen(true);
    return GalleryPane;
  },
  variants: {
    opened: {
      note: "Open: in the gutter at 1600px (nothing moves), pushing the chat by part of its width at 1200px, by all of it at 740px.",
      props: { surface: "transcript" },
      play: async (ctx) => {
        const closed = 'button.acpmux-session-info-toggle[aria-pressed="false"]';
        await ctx.waitFor(() => ctx.document.querySelector("button.acpmux-session-info-toggle"));
        if (ctx.document.querySelector(closed)) await ctx.click({ selector: closed });
        await ctx.waitFor(
          () => ctx.document.querySelector("aside.acpmux-session-info")?.getAttribute("data-presence") === "shown",
        );
      },
    },
  },
});
