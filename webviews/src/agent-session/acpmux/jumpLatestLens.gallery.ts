// l10n-allow-file: sample transcript and comparison labels, not shipped UI.
// Jump to latest as a fisheye lens (ui/glass/Fisheye.tsx, glass.css FISHEYE). Leo, 2026-10-21:
// "I want, like glassier stuff. I want it to be like a fucking glass, like a lens thing, like a
// fisheye. I want more fisheye!" Each variant parks the reader mid-chat, lifts the button into the
// prose so words sit under it, then sets one strength; medium is the one that ships.
import { agentPaneEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { assistant, chat, summary, user } from "../../gallery/fixtures/acpmux";
import { fisheyeFilterId, type FisheyeStrength } from "../../ui/glass/Fisheye";

const snapshot = chat(
  Array.from({ length: 24 }, (_, index) => [
    user(`Check retry case ${index + 1}`, 50 - index * 2),
    assistant(
      `Case ${index + 1} passes. The client retries a temporary transport failure, keeps the original request id, and stops after the last attempt. The next check verifies that the same response reaches the caller exactly once, and that it inserts nothing between the retries. `.repeat(
        4,
      ),
      49 - index * 2,
    ),
    summary(49 - index * 2, { status: "completed" }),
  ]).flat(),
);

/** How far each variant lifts the button over the prose (the app keeps it 12 px over the composer). */
const LIFT_PX = 140;

const park =
  (strength?: FisheyeStrength): Play =>
  async (ctx) => {
    await ctx.waitFor(() => (ctx.document.querySelector<HTMLElement>(".acpmux-scroll")?.scrollHeight ?? 0) > 1_000);
    await ctx.scroll({ selector: ".acpmux-scroll" }, 1_200);
    await ctx.waitFor(() => ctx.document.querySelector(".acpmux-jump-latest[data-shown]"));
    const button = ctx.document.querySelector<HTMLElement>(".acpmux-jump-latest");
    // Lifted off the composer's soft edge into the prose, so the lens has words to bend.
    button?.style.setProperty("bottom", `calc(12px + var(--acpmux-dock-space, 0px) + ${LIFT_PX}px)`);
    if (strength) button?.style.setProperty("--glass-fisheye", `url(#${fisheyeFilterId(strength)})`);
  };

export default agentPaneEntry({
  id: "agent-pane.jump-latest-lens",
  title: "Jump to latest fisheye lens",
  area: "Agent pane",
  height: 700,
  covers: ["ui/glass/Fisheye.tsx", "agent-session/acpmux/App.tsx#VirtualTranscript"],
  checks: {
    anchorMovePx: { value: 0, reason: "The lens bends only what the button draws; no row or composer moves." },
  },
  variants: {
    soft: {
      note: "Soft: 1.4x in the middle; the words under the disc grow a little and bend at the rim.",
      snapshot,
      play: park("soft"),
    },
    medium: {
      note: "Selected (ships): 1.8x in the middle; the most fisheye strength whose arrow and words still read.",
      snapshot,
      play: park(),
    },
    strong: {
      note: "Strong: 2.5x in the middle; a letter or two fills the disc and the arrow fights the text.",
      snapshot,
      play: park("strong"),
    },
  },
});
