// l10n-allow-file: gallery entry notes, not shipped UI.
// Session Info's three places by the pane's width (SessionInfo.tsx sessionInfoStage; Leo, 2026-11-03:
// "we previously had all that behaviour logic going from not affecting layout at all -> gradually
// pushing into the chat layout -> overlay"). At 1600px the right gutter holds the panel and the chat
// does not move; at 1200px it pushes the transcript's column left by only what the gutter lacks
// (pushedRoom), the column at its own width; at 1100px a push would narrow the 800px column, so it
// lies over the chat above the composer (Leo, 2026-11-03: "the agent chat's horizontal width
// shouldn't be shifted its position sure but it itself and its text shouldn't be affected by the
// session info if it would need to be then session info should be an overlay"). Narrow panes:
// agent-pane.session-info-narrow-pane. Leo, 2026-11-09: "if it has enough space, then don't push the
// layout. Don't make it affect the layout. You only push when you don't have any space left".
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { setChatDisplay } from "../chatDisplay";
import { setHeaderState } from "../header/headerState";
import { setSessionInfoOpen } from "./sessionInfoState";
import { GalleryPane } from "./SessionInfoSurfaces.gallery";

/// Opens or closes the panel with its toggle under a placement (Settings > Agent Chat > Session Info).
const place =
  (placement: "overlay" | "push", open: boolean): Play =>
  async (ctx) => {
    setChatDisplay({ "agentPane.display.sessionInfo.placement": placement });
    const wrong = `button.acpmux-session-info-toggle[aria-pressed="${open ? "false" : "true"}"]`;
    await ctx.waitFor(() => ctx.document.querySelector("button.acpmux-session-info-toggle"));
    if (ctx.document.querySelector(wrong)) await ctx.click({ selector: wrong });
    if (open)
      await ctx.waitFor(
        () => ctx.document.querySelector("aside.acpmux-session-info")?.getAttribute("data-presence") === "shown",
      );
    else await ctx.waitFor(() => !ctx.document.querySelector("aside.acpmux-session-info"));
  };

export default componentEntry<{ surface: "transcript" }>({
  id: "agent-pane.session-info-stages",
  title: "Session Info floats, pushes the column without narrowing it, or lies over the chat, by the pane's width",
  area: "Agent pane",
  pane: true,
  height: 640,
  widths: { narrow: 1100, normal: 1200, wide: 1600 },
  covers: ["agent-session/acpmux/session-info/SessionInfo.tsx#SessionInfoPanel"],
  load: async () => {
    setHeaderState({ inspector: true });
    setSessionInfoOpen(true);
    return GalleryPane;
  },
  variants: {
    closed: {
      note: "Closed, where the chat's column sits at each width: the open variants compare against it.",
      props: { surface: "transcript" },
      play: place("overlay", false),
    },
    opened: {
      note: "Open (default): in the gutter at 1600px with the column exactly where it is closed, pushing the column left by only what the gutter lacks at 1200px, over the chat above the composer at 1100px.",
      props: { surface: "transcript" },
      play: place("overlay", true),
    },
    "push-always": {
      note: "Settings Push always: it takes its whole room at 1600px and 1200px, so the column moves left even where the gutter has room; over the chat at 1100px.",
      props: { surface: "transcript" },
      play: place("push", true),
    },
  },
});
