// l10n-allow-file: gallery entry notes, not shipped UI.
// Session Info's three places by the pane's width (SessionInfo.tsx sessionInfoStage; Leo, 2026-11-03:
// "we previously had all that behaviour logic going from not affecting layout at all -> gradually
// pushing into the chat layout -> overlay"). At 1600px the right gutter holds the panel and the chat
// does not move; at 1200px it pushes the transcript's column left by only what the gutter lacks
// (pushedRoom), the column at its own width; at 1100px a push would narrow the 800px column, so it
// lies over the chat above the composer (Leo, 2026-11-03: "the agent chat's horizontal width
// shouldn't be shifted its position sure but it itself and its text shouldn't be affected by the
// session info if it would need to be then session info should be an overlay"). Narrow panes:
// agent-pane.session-info-narrow-pane.
import { componentEntry } from "../../../gallery/format";
import { setHeaderState } from "../header/headerState";
import { setSessionInfoOpen } from "./sessionInfoState";
import { GalleryPane } from "./SessionInfoSurfaces.gallery";

export default componentEntry<{ surface: "transcript" }>({
  id: "agent-pane.session-info-stages",
  title: "Session Info floats, pushes the column without narrowing it, or lies over the chat, by the pane's width",
  area: "Agent pane",
  pane: true,
  height: 640,
  widths: { narrow: 1100, normal: 1200, wide: 1600 },
  covers: [
    "agent-session/acpmux/session-info/SessionInfo.tsx#sessionInfoStage",
    "agent-session/acpmux/session-info/SessionInfo.tsx#pushedRoom",
    "agent-session/acpmux/session-info/SessionInfo.tsx#pushKeepsColumn",
  ],
  load: async () => {
    setHeaderState({ inspector: true });
    setSessionInfoOpen(true);
    return GalleryPane;
  },
  variants: {
    opened: {
      note: "Open: in the gutter at 1600px (nothing moves), pushing the column left at its own width at 1200px, over the chat above the composer at 1100px.",
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
