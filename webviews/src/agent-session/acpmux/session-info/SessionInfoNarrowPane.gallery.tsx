// l10n-allow-file: gallery entry notes, not shipped UI.
// Session Info in a narrow agent pane (cmuxterm-hq#6137). A 370px pane (a split of a 740pt window) and a
// 528px one cannot hold a readable chat beside the panel, so a saved open state leaves the chat alone;
// the toggle opens it over the chat, its foot above the composer (SessionInfo.tsx sessionInfoStage
// `overlay`; Leo, 2026-11-03: "but you should still be able to have it be an overlay"). A 740px pane
// opens it unasked, over the chat too: a push would narrow the transcript's column (Leo, 2026-11-03: "if
// it would need to be then session info should be an overlay"). The wider stages
// are agent-pane.session-info-stages (SessionInfoStages.gallery.tsx).
import { componentEntry } from "../../../gallery/format";
import { setHeaderState } from "../header/headerState";
import { setSessionInfoOpen } from "./sessionInfoState";
import { GalleryPane } from "./SessionInfoSurfaces.gallery";

export default componentEntry<{ surface: "transcript" }>({
  id: "agent-pane.session-info-narrow-pane",
  title: "Session Info in a narrow pane lies over the chat, above the composer",
  area: "Agent pane",
  pane: true,
  height: 640,
  widths: { narrow: 370, normal: 528, wide: 740 },
  covers: [
    "agent-session/acpmux/session-info/SessionInfo.tsx#sessionInfoStage",
    "agent-session/acpmux/session-info/SessionInfo.tsx#pushedWidth",
  ],
  load: async () => {
    setHeaderState({ inspector: true });
    setSessionInfoOpen(true);
    return GalleryPane;
  },
  variants: {
    "saved-open": {
      note: "Saved open, in a pane too narrow for a readable chat beside the panel: the chat shows alone until the toggle opens Session Info.",
      props: { surface: "transcript" },
    },
    opened: {
      note: "At 370 and 528px the toggle opened it, at 740px it opened unasked: it lies over the chat and stops above the composer, which stays whole, since a push would narrow the transcript's column.",
      props: { surface: "transcript" },
      play: async (ctx) => {
        // A pane too narrow for a readable chat beside it waits for the toggle; a wider one has it open.
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
