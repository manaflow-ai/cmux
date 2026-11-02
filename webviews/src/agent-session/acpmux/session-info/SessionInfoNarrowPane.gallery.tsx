// Session Info in a narrow agent pane (cmuxterm-hq#6137; Leo, 2026-11-02: "THE FUCKING SESSION INFO NOT
// FUCKING PUSH THE LAYOUT LEFT"). A 370px pane (a split of a 740pt window) and a 528px one cannot hold
// a readable chat beside the panel, so a saved open state leaves the chat alone; the toggle opens it,
// and it pushes the chat left at its narrow floor (SessionInfo.tsx PUSH_PANEL_MIN), never over it.
import { componentEntry } from "../../../gallery/format";
import { setHeaderState } from "../header/headerState";
import { setSessionInfoOpen } from "./sessionInfoState";
import { GalleryPane } from "./SessionInfoSurfaces.gallery";

export default componentEntry<{ surface: "transcript" }>({
  id: "agent-pane.session-info-narrow-pane",
  title: "Session Info in a narrow pane pushes the chat",
  area: "Agent pane",
  pane: true,
  height: 640,
  widths: { narrow: 370, normal: 528 },
  covers: ["agent-session/acpmux/session-info/SessionInfo.tsx#pushedWidth"],
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
      note: "The toggle opened it: the panel narrows to 200px and sits right of the chat, which reflows beside it.",
      props: { surface: "transcript" },
      play: async (ctx) => {
        await ctx.click({ selector: "button.acpmux-session-info-toggle" });
        await ctx.waitFor(
          () => ctx.document.querySelector("aside.acpmux-session-info")?.getAttribute("data-presence") === "shown",
        );
      },
    },
  },
});
